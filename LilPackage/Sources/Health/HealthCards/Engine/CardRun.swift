public import Foundation
import HealthCatalog

/// A card spec run over one period, the engine's shared core (docs/decisions/cards.md, What an
/// engine computes): it says what to fetch (`fetches`), and computes `CardData` from what was
/// fetched (`compute(_:)`), so the Mac (SQLite) and the iPhone (HealthKit) fetch differently and
/// compute identically.
///
/// ```swift
/// var run = CardRun(spec: spec, range: .month, date: date, now: now, calendar: calendar)
/// if !run.windowFetches.isEmpty {
///   run = run.windowed(try run.windowFetches.map { try fetchWindow($0) })
/// }
/// let data = run.compute(try run.fetches.map { try fetch($0) })
/// ```
///
/// Sleep and workout windows take two steps (851-3196): their nights' sleep records and their
/// workouts first (`windowFetches`), which `windowed(_:)` turns into stretches, then only the
/// readings in those stretches (`CardFetch.Kind.stretchReadings`). Until it's windowed, a series
/// with one fetches nothing and has no points.
public struct CardRun: Sendable {
  public let spec: CardSpec
  /// The range it's for, or `nil` for a headline's buckets.
  public let range: CardRange?
  /// The period: only readings starting in it count.
  public let interval: DateInterval
  /// What each point covers.
  public let grain: CardGrain
  public let calendar: Calendar
  /// What to fetch, in the spec's series order. `compute(_:)` takes a result for each.
  public let fetches: [CardFetch]
  /// What sleep and workout windows need first: their nights' sleep records and workouts, at most
  /// one of each. Empty when no series has one, or once `windowed(_:)`.
  public let windowFetches: [CardWindowFetch]
  /// Each windowed series' stretches, by its index, once `windowed(_:)`.
  let windows: [Int: Stretches]

  /// A sleep or workout window's stretches for one series, in order and apart.
  struct Stretches: Sendable {
    var stretches: [CardStretch]
    /// For a sleep window, the night (its day) each stretch belongs to, where its readings go.
    var nights: [Date]?
  }

  /// The period of `range` containing `date`, as a card's page shows it. `now` places 6M's
  /// periods: the six months ending with its month, then the six before them.
  public init(spec: CardSpec, range: CardRange, date: Date, now: Date, calendar: Calendar) {
    self.init(
      spec: spec, range: range,
      interval: range.interval(containing: date, now: now, calendar: calendar),
      grain: spec.bucket.grain(at: range), calendar: calendar, windows: nil)
  }

  /// The `buckets` buckets ending with the one containing `date`, as a Summary row's sparkline
  /// shows them: the card's buckets, with `auto` as days.
  public init(
    headlineOf spec: CardSpec, endingOn date: Date, calendar: Calendar,
    buckets: Int = CardHeadline.sparklineBuckets
  ) {
    let grain = CardHeadline.grain(of: spec)
    let start = calendar.bucketStart(grain, buckets - 1, before: date)
    let end = calendar.dateInterval(of: grain.component, for: date)?.end ?? date
    self.init(
      spec: spec, range: nil, interval: DateInterval(start: start, end: end), grain: grain,
      calendar: calendar, windows: nil)
  }

  /// `windows`: each windowed series' stretches, or `nil` before `windowed(_:)`.
  private init(
    spec: CardSpec, range: CardRange?, interval: DateInterval, grain: CardGrain,
    calendar: Calendar, windows: [Int: Stretches]?
  ) {
    self.spec = spec
    self.range = range
    self.interval = interval
    self.grain = grain
    self.calendar = calendar
    self.windows = windows ?? [:]
    var fetches: [CardFetch] = []
    for (index, series) in spec.series.enumerated() {
      fetches += Self.fetches(
        for: series, at: index, spec: spec, range: range, interval: interval, grain: grain,
        calendar: calendar, stretches: windows?[index])
    }
    self.fetches = fetches
    windowFetches =
      windows == nil
      ? Self.windowFetches(spec: spec, interval: interval, grain: grain, calendar: calendar) : []
  }

  // MARK: - Windows

  /// Where a windowed series' readings can come from: its period, and the whole buckets before
  /// it its moving average needs. For a sleep window, the days whose nights count.
  private static func windowSpan(
    of series: CardSpec.Series, spec: CardSpec, interval: DateInterval, grain: CardGrain,
    calendar: Calendar
  ) -> Range<Date> {
    let history = history(of: series, spec: spec, interval: interval, grain: grain, calendar)
    return (history?.lowerBound ?? interval.start)..<interval.end
  }

  /// The days whose nights the sleep windows need, and the span the workout windows do: each
  /// the union of its series' spans.
  private static func windowSpans(
    spec: CardSpec, interval: DateInterval, grain: CardGrain, calendar: Calendar
  ) -> (nights: Range<Date>?, workouts: Range<Date>?) {
    var nights: Range<Date>?
    var workouts: Range<Date>?
    for series in spec.series where series.aggregation != .sum {
      func widen(_ span: inout Range<Date>?) {
        let own = windowSpan(
          of: series, spec: spec, interval: interval, grain: grain, calendar: calendar)
        span =
          span.map { min($0.lowerBound, own.lowerBound)..<max($0.upperBound, own.upperBound) }
          ?? own
      }
      switch series.window {
      case .asleep, .beforeSleep, .afterWaking: widen(&nights)
      case .workout: widen(&workouts)
      case nil, .timeOfDay: break
      }
    }
    return (nights, workouts)
  }

  private static func windowFetches(
    spec: CardSpec, interval: DateInterval, grain: CardGrain, calendar: Calendar
  ) -> [CardWindowFetch] {
    let spans = windowSpans(spec: spec, interval: interval, grain: grain, calendar: calendar)
    var fetches: [CardWindowFetch] = []
    if let nights = spans.nights { fetches.append(.sleep(CardNights.recordRange(days: nights))) }
    if let workouts = spans.workouts {
      fetches.append(
        .workouts(workouts.lowerBound.unixMilliseconds..<workouts.upperBound.unixMilliseconds))
    }
    return fetches
  }

  /// The run with its sleep and workout windows' stretches, from a result for each of
  /// `windowFetches`, in their order: its `fetches` then read each windowed series' readings in
  /// its stretches. A run without window fetches, or windowed already, is returned as it is.
  public func windowed(_ results: [CardWindowFetchResult]) -> CardRun {
    guard !windowFetches.isEmpty else { return self }
    precondition(results.count == windowFetches.count, "A result for each window fetch.")
    var records: [CardSleepRecord] = []
    var workouts: [CardWorkout] = []
    for (fetch, result) in zip(windowFetches, results) {
      switch (fetch, result) {
      case (.sleep, .sleep(let fetched)): records = fetched
      case (.workouts, .workouts(let fetched)): workouts = fetched
      default: preconditionFailure("A result of each window fetch's kind.")
      }
    }
    let days = Self.windowSpans(spec: spec, interval: interval, grain: grain, calendar: calendar)
      .nights
    let nights = days.map { CardNights.nights(records, days: $0, calendar: calendar) } ?? []
    // A bucket that starts before the period counts only the period's nights (6M's first week),
    // and a moving average's buckets are whole ones before it.
    let firstBucket = calendar.bucketStart(grain, 0, before: interval.start)
    var windows: [Int: Stretches] = [:]
    for (index, series) in spec.series.enumerated() where series.aggregation != .sum {
      guard let window = series.window else { continue }
      let span = Self.windowSpan(
        of: series, spec: spec, interval: interval, grain: grain, calendar: calendar)
      switch window {
      case .asleep, .beforeSleep, .afterWaking:
        let (stretches, days) = CardWindows.sleepStretches(
          window,
          nights: nights.filter {
            span.contains($0.day) && ($0.day >= interval.start || $0.day < firstBucket)
          }, calendar: calendar)
        windows[index] = Stretches(stretches: stretches, nights: days)
      case .workout(let activities):
        // Up to the longest weight past the period, which is all its last readings' weights need.
        let end = interval.end.unixMilliseconds + Int(CardWeights.maxSampleWeight * 1000)
        windows[index] = Stretches(
          stretches: CardWindows.workoutStretches(
            activities: activities, workouts: workouts,
            in: span.lowerBound.unixMilliseconds..<end),
          nights: nil)
      case .timeOfDay:
        break
      }
    }
    return CardRun(
      spec: spec, range: range, interval: interval, grain: grain, calendar: calendar,
      windows: windows)
  }

  // MARK: - What to fetch

  private static func fetches(
    for series: CardSpec.Series, at index: Int, spec: CardSpec, range: CardRange?,
    interval: DateInterval, grain: CardGrain, calendar: Calendar, stretches: Stretches?
  ) -> [CardFetch] {
    let history = history(of: series, spec: spec, interval: interval, grain: grain, calendar)
    if series.aggregation == .sum {
      let totalsGrain = averagesDays(series, spec: spec, range: range) ? .day : grain
      var fetches = [
        CardFetch(
          series: index, type: series.type, purpose: .period,
          kind: .totals(interval.start..<interval.end, grain: totalsGrain))
      ]
      if let history {
        fetches.append(
          CardFetch(
            series: index, type: series.type, purpose: .history,
            kind: .totals(history, grain: totalsGrain)))
      }
      return fetches
    }
    let needsSampleIDs = series.aggregation == .first || series.aggregation == .latest
    switch series.window {
    case nil, .timeOfDay: break
    case .asleep, .beforeSleep, .afterWaking, .workout:
      // Only once windowed: the readings in its stretches.
      guard let stretches else { return [] }
      return [
        CardFetch(
          series: index, type: series.type, purpose: .period,
          kind: .stretchReadings(
            stretches.stretches, filter: series.filter, needsSampleIDs: needsSampleIDs))
      ]
    }
    let lower = (history?.lowerBound ?? interval.start).unixMilliseconds
    var upper = interval.end.unixMilliseconds
    if series.dataType?.aggregation == .discreteTemporallyWeighted {
      // The next reading after the period's last, for its weight.
      upper += Int(CardWeights.maxSampleWeight * 1000)
    }
    return [
      CardFetch(
        series: index, type: series.type, purpose: .period,
        kind: .readings(lower..<upper, filter: series.filter, needsSampleIDs: needsSampleIDs))
    ]
  }

  /// Whether a series' points are the average day of each week or month: a total with `auto` at
  /// 6M or Y, as Metric Detail (Health's DAILY AVERAGE).
  static func averagesDays(_ series: CardSpec.Series, spec: CardSpec, range: CardRange?) -> Bool {
    series.aggregation == .sum && spec.bucket == .auto
      && (range == .sixMonths || range == .year)
  }

  /// The whole buckets before the period a moving average of the series needs, so its first
  /// points have their full window; `nil` when none does.
  private static func history(
    of series: CardSpec.Series, spec: CardSpec, interval: DateInterval, grain: CardGrain,
    _ calendar: Calendar
  ) -> Range<Date>? {
    let points = spec.formulas.compactMap { formula -> Int? in
      guard case .movingAverage(let of, let points) = formula.operation, of == series.id else {
        return nil
      }
      return points
    }
    .max()
    guard let points, points > 1 else { return nil }
    let first = calendar.bucketStart(grain, 0, before: interval.start)
    let start = calendar.bucketStart(grain, points - 1, before: interval.start)
    return start < first ? start..<first : nil
  }

  // MARK: - Computing

  /// The card's data from a result for each of `fetches`, in their order: totals for `.totals`,
  /// readings (oldest first) for `.readings`.
  public func compute(_ results: [CardFetchResult]) -> CardData {
    precondition(results.count == fetches.count, "A result for each fetch.")
    var computed: [Computed] = spec.series.map { _ in Computed() }
    for (fetch, result) in zip(fetches, results) {
      let series = spec.series[fetch.series]
      switch result {
      case .totals(let totals):
        computed[fetch.series].addTotals(
          totals, purpose: fetch.purpose,
          averagesDays: Self.averagesDays(series, spec: spec, range: range),
          grain: grain, calendar: calendar)
      case .readings(let readings):
        computed[fetch.series].addReadings(
          readings, of: series, stretches: windows[fetch.series], run: self)
      }
    }
    let seriesData = zip(spec.series, computed).map { series, computed in
      CardData.Series(
        id: series.id, label: series.label ?? series.dataType?.name ?? series.type,
        type: series.type, aggregation: series.aggregation, unit: series.valueUnit,
        hidden: series.hidden, points: computed.points)
    }
    let formulas = spec.formulas.map { formula in
      CardData.Formula(
        id: formula.id, kind: formula.operation.kind, label: formula.label,
        unit: spec.valueUnit(of: formula) ?? .readings, hidden: formula.hidden,
        points: points(of: formula, computed: computed))
    }
    return CardData(
      range: range, interval: interval, bucket: spec.bucket, grain: grain, series: seriesData,
      formulas: formulas, summary: summary(computed: computed, formulas: formulas),
      goal: spec.chart.goal?.value)
  }

  /// A series' points, and what its summary and formulas need.
  struct Computed {
    var points: [CardPoint] = []
    /// Values of the whole buckets before the period, by start, for moving averages.
    var history: [Date: Double] = [:]
    /// The period's totals as fetched (days, for an average day), above 0.
    var totals: [CardTotal] = []
    /// Every reading in the period.
    var period: CardBucket?

    mutating func addTotals(
      _ totals: [CardTotal], purpose: CardFetch.Purpose, averagesDays: Bool, grain: CardGrain,
      calendar: Calendar
    ) {
      // Days with a total above 0 are the ones with data.
      let totals = totals.filter { $0.sum > 0 }.sorted { $0.start < $1.start }
      let points =
        averagesDays
        ? CardTotals.averageDays(totals, by: grain, calendar: calendar)
        : totals.map { CardPoint(start: $0.start, value: $0.sum) }
      switch purpose {
      case .period:
        self.totals = totals
        self.points = points
      case .history:
        for point in points { history[point.start] = point.value }
      }
    }

    /// `stretches`: a sleep or workout window's.
    mutating func addReadings(
      _ readings: [CardReading], of series: CardSpec.Series, stretches: Stretches?, run: CardRun
    ) {
      let aggregation = series.dataType?.aggregation ?? .discreteArithmetic
      let keepsOrder = series.aggregation == .first || series.aggregation == .latest
      var readings = readings
      let weights: [Double]
      // Where each reading goes, in Unix milliseconds, when it isn't its start: its night's day.
      var places: [Int]?
      if let stretches {
        let kept = CardWindows.readings(readings, in: stretches.stretches)
        readings = kept.readings
        weights = CardWeights.weights(
          of: readings, stretches: stretches.stretches, stretchIndices: kept.stretchIndices,
          aggregation)
        if let nights = stretches.nights {
          places = kept.stretchIndices.map { nights[$0].unixMilliseconds }
        }
      } else if case .timeOfDay(let window) = series.window, let first = readings.first,
        let last = readings.last
      {
        // A stretch past the last reading only matters up to the longest weight.
        let reach = Int(CardWeights.maxSampleWeight * 1000) + 1
        let stretches = window.stretches(
          in: first.start..<(last.start + reach), timeZone: run.calendar.timeZone)
        let kept = CardWindows.readings(readings, in: stretches)
        readings = kept.readings
        weights = CardWeights.weights(
          of: readings, stretches: stretches, stretchIndices: kept.stretchIndices, aggregation)
      } else {
        weights = CardWeights.weights(of: readings, aggregation)
      }

      let periodStart = run.interval.start.unixMilliseconds
      let periodEnd = run.interval.end.unixMilliseconds
      let firstBucket = run.calendar.bucketStart(run.grain, 0, before: run.interval.start)
        .unixMilliseconds
      var bucketer = CardBucketer(run.grain, calendar: run.calendar)
      var buckets = Buckets()
      var earlier = Buckets()
      var period = CardBucket(aggregation, keepsOrder: keepsOrder)
      func add(_ reading: CardReading, _ weight: Double, at place: Int, to buckets: inout Buckets) {
        buckets.add(
          reading, weight: weight, at: bucketer.start(ofMilliseconds: place),
          new: CardBucket(aggregation, keepsOrder: keepsOrder))
      }
      for (index, (reading, weight)) in zip(readings, weights).enumerated() {
        let place = places?[index] ?? reading.start
        if place >= periodEnd {
          // Readings come by start, and so do their places, but nights' days needn't.
          if places == nil { break } else { continue }
        }
        if place >= periodStart {
          add(reading, weight, at: place, to: &buckets)
          period.add(reading, weight: weight)
        } else if place < firstBucket {
          add(reading, weight, at: place, to: &earlier)
        }
      }
      let value = { (bucket: CardBucket) in bucket.value(series.aggregation) }
      points = buckets.sorted.compactMap { start, bucket in
        guard let value = value(bucket) else { return nil }
        return series.aggregation == .count
          ? CardPoint(start: start, value: value, readings: bucket.count)
          : CardPoint(
            start: start, value: value, minimum: bucket.minimum, maximum: bucket.maximum,
            readings: bucket.count)
      }
      for (start, bucket) in earlier.sorted {
        history[start] = value(bucket)
      }
      self.period = period.count > 0 ? period : nil
    }
  }

  /// Buckets by start, added to as readings come: in order but for nights whose stretches
  /// overlap, whose readings can come back to a bucket.
  struct Buckets {
    private var list: [(start: Date, bucket: CardBucket)] = []
    private var index: [Date: Int] = [:]
    private var inOrder = true

    mutating func add(
      _ reading: CardReading, weight: Double, at start: Date, new: @autoclosure () -> CardBucket
    ) {
      if list.last?.start != start {
        if let existing = index[start] {
          list[existing].bucket.add(reading, weight: weight)
          return
        }
        if let last = list.last?.start, start < last { inOrder = false }
        index[start] = list.count
        list.append((start, new()))
      }
      list[list.count - 1].bucket.add(reading, weight: weight)
    }

    var sorted: [(start: Date, bucket: CardBucket)] {
      inOrder ? list : list.sorted { $0.start < $1.start }
    }
  }

  // MARK: - Formulas

  private func points(of formula: CardSpec.Formula, computed: [Computed]) -> [CardFormulaPoint] {
    func series(_ id: String) -> Computed? {
      spec.series.firstIndex { $0.id == id }.map { computed[$0] }
    }
    switch formula.operation {
    case .movingAverage(let of, let count):
      guard let series = series(of), let firstPoint = series.points.first else { return [] }
      // Every bucket from the earliest the window reaches, empty ones included.
      let starts = calendar.bucketStarts(
        grain, from: calendar.bucketStart(grain, count - 1, before: firstPoint.start),
        to: interval.end)
      var values = series.history
      for point in series.points { values[point.start] = point.value }
      let index = Dictionary(starts.enumerated().map { ($1, $0) }) { first, _ in first }
      return series.points.compactMap { point in
        guard let position = index[point.start] else { return nil }
        let window = starts[max(0, position - count + 1)...position].compactMap { values[$0] }
        return CardFormulaPoint(
          start: point.start, value: window.reduce(0, +) / Double(window.count))
      }
    case .difference(let a, let b):
      guard let minuend = series(a), let subtrahend = series(b) else { return [] }
      let values = Dictionary(subtrahend.points.map { ($0.start, $0.value) }) { first, _ in first }
      return minuend.points.compactMap { point in
        values[point.start].map { CardFormulaPoint(start: point.start, value: point.value - $0) }
      }
    }
  }

  // MARK: - Summary

  private func summary(computed: [Computed], formulas: [CardData.Formula]) -> CardSummary? {
    switch spec.lead {
    case nil:
      return nil
    case .formula(let lead):
      guard let points = formulas.first(where: { $0.id == lead.id })?.points, !points.isEmpty
      else { return nil }
      return CardSummary(
        kind: .average, value: points.reduce(0) { $0 + $1.value } / Double(points.count))
    case .series(let lead):
      guard let index = spec.series.firstIndex(of: lead) else { return nil }
      let computed = computed[index]
      if lead.aggregation == .sum {
        return totalSummary(computed)
      }
      guard let period = computed.period else { return nil }
      switch lead.aggregation {
      case .avg where spec.chart.style == .ranges:
        // As Metric Detail: a range, unless every reading was the same.
        return period.minimum == period.maximum
          ? CardSummary(kind: .average, value: period.minimum)
          : CardSummary(
            kind: .range, value: nil, minimum: period.minimum, maximum: period.maximum)
      case .avg: return CardSummary(kind: .average, value: period.average.average)
      case .min: return CardSummary(kind: .lowest, value: period.minimum)
      case .max: return CardSummary(kind: .highest, value: period.maximum)
      case .first: return CardSummary(kind: .first, value: period.first?.value)
      case .latest: return CardSummary(kind: .latest, value: period.latest?.value)
      case .count: return CardSummary(kind: .count, value: Double(period.count))
      case .sum: return nil
      }
    }
  }

  /// A total's header: a day's total at D, else its average day (or bucket) with data, as Metric
  /// Detail's AVERAGE and DAILY AVERAGE.
  private func totalSummary(_ computed: Computed) -> CardSummary? {
    let totals = computed.totals
    guard !totals.isEmpty else { return nil }
    let total = totals.reduce(0) { $0 + $1.sum }
    let average = total / Double(totals.count)
    if spec.bucket == .auto, let range {
      switch range {
      case .day: return CardSummary(kind: .total, value: total)
      case .week, .month: return CardSummary(kind: .average, value: average)
      case .sixMonths, .year: return CardSummary(kind: .dailyAverage, value: average)
      }
    }
    let buckets = calendar.bucketStarts(grain, from: interval.start, to: interval.end).count
    return CardSummary(
      kind: buckets == 1 ? .total : .average, value: buckets == 1 ? total : average)
  }
}

/// Something a run needs fetched for one of its series.
public struct CardFetch: Hashable, Sendable {
  /// The series' index in the spec.
  public var series: Int
  /// Its type's HealthKit identifier.
  public var type: String
  public var purpose: Purpose
  public var kind: Kind

  public init(series: Int, type: String, purpose: Purpose, kind: Kind) {
    self.series = series
    self.type = type
    self.purpose = purpose
    self.kind = kind
  }

  public enum Purpose: Hashable, Sendable {
    /// The period's data.
    case period
    /// Whole buckets before the period, for a moving average. Readings fetch them with the
    /// period's, in one range.
    case history
  }

  public enum Kind: Hashable, Sendable {
    /// A cumulative type's de-duplicated totals per bucket of `grain`, from buckets starting in
    /// the range: the Mac's `cumulativeTotals`, the iPhone's `HKStatisticsCollectionQuery`.
    case totals(Range<Date>, grain: CardGrain)
    /// The type's readings starting in the range (Unix milliseconds), oldest first, that match
    /// the filter. `needsSampleIDs`: whether `CardReading.sampleID` is used (`first` and
    /// `latest`'s ties); otherwise it may be left empty.
    case readings(Range<Int>, filter: CardSpec.Filter?, needsSampleIDs: Bool)
    /// The same, for a sleep or workout window, once windowed: the readings starting in one of the
    /// stretches (in order and apart, Unix milliseconds), oldest first. Readings outside them may
    /// be included (the run keeps those in a stretch), such as a fetch over a stretch's
    /// neighbours.
    case stretchReadings([CardStretch], filter: CardSpec.Filter?, needsSampleIDs: Bool)
  }
}

/// What was fetched for a `CardFetch`.
public enum CardFetchResult: Hashable, Sendable {
  case totals([CardTotal])
  case readings([CardReading])
}

public enum CardTotals {
  /// The average day of each bucket of `grain` (a week for 6M, a month for Y), among `days` (in
  /// order) that have a total: Health's DAILY AVERAGE. Metric Detail's too.
  public static func averageDays(
    _ days: [CardTotal], by grain: CardGrain, calendar: Calendar
  ) -> [CardPoint] {
    var groups: [(start: Date, sum: Double, days: Int)] = []
    var bucketer = CardBucketer(grain, calendar: calendar)
    for day in days {
      let start = bucketer.start(of: day.start)
      if groups.last?.start == start {
        groups[groups.count - 1].sum += day.sum
        groups[groups.count - 1].days += 1
      } else {
        groups.append((start, day.sum, 1))
      }
    }
    return groups.map { CardPoint(start: $0.start, value: $0.sum / Double($0.days)) }
  }
}
