/// Quantity series' values as readings (851-4172, docs/decisions/cards.md › Readings and weights).
///
/// A quantity sample whose `count` is over 1 (a Watch's heart rate in a workout, an app's samples
/// written with `HKQuantitySeriesSampleBuilder`) is a series: its value is HealthKit's for the
/// whole series (the average of a discrete one), and its values each have their own time. Every
/// engine reads a series as its values, one reading each, with the sample's source and ID, so an
/// average weighs each value, time weighting runs from value to value, and `min` and `max` see
/// each one. The Mac and the server read them from `health_quantity_series`, the iPhone from
/// HealthKit (`HKQuantitySeriesSampleQuery`). A series uploaded without its values (more than the
/// iPhone sends, `HealthEncoder.maxSeriesValues`) stays one reading on the Mac and the server.
///
/// A value is a reading where it starts, like any other, so a series that starts before a range
/// can have values in it: engines read the series starting up to `reach` before the range
/// (`starts(for:)`), and keep the values starting in it. The tools read series by the same rules
/// (851-4171, the Mac's `QuantitySeriesReadings.swift`, the server's `tools/HealthQueries.ts`).
public enum CardSeries {
  /// How long after its start (in milliseconds) a series' values count: a week, the tools'
  /// `seriesLookback` (851-4171). A range reads the series that started this long before it too;
  /// values later than that, or after the sample's end, count nowhere, so what a range reads
  /// doesn't depend on where it starts. The iPhone uploads at most 20,000 values a series: a
  /// week of them every 30 s.
  public static let reach = 7 * 86_400_000

  /// The starts of the series whose values can start in `range`.
  public static func starts(for range: Range<Int>) -> Range<Int> {
    (range.lowerBound - reach)..<range.upperBound
  }

  /// One series: its sample, as a reading, and its values, in order.
  public struct Series: Sendable {
    public var sample: CardReading
    /// `nil` when it was uploaded without them, or they don't line up: then it's read as its
    /// sample.
    public var values: [CardReading]?

    /// `values`: every value HealthKit has, in order, of which those that count are kept
    /// (`counts(_:)`).
    public init(sample: CardReading, values: [CardReading]?) {
      self.sample = sample
      self.values = values?.filter { Self.counts($0.start, of: sample) }
    }

    /// Whether a value starting at `start` counts: by the sample's end, and less than `reach`
    /// after its start.
    static func counts(_ start: Int, of sample: CardReading) -> Bool {
      start <= sample.end && start < sample.start + reach
    }

    /// A time or duration the tools take: from 0 to 1e9 s (about 31 years).
    private static func isSeconds(_ seconds: Double) -> Bool { seconds >= 0 && seconds <= 1e9 }

    /// From `health_quantity_series`' arrays: each value's start and duration in seconds since
    /// the series' `start` (Unix milliseconds), to the millisecond, and the value in the type's
    /// catalog unit. Values are `nil` when there are none, the arrays don't have one entry each
    /// (which the server refuses), or a time or duration isn't from 0 to 1e9 s, as the tools
    /// read them. Only those that count are kept (`counts(_:of:)`).
    public init(
      sample: CardReading, start: Int, times: [Double], durations: [Double], values: [Double]
    ) {
      self.sample = sample
      guard !times.isEmpty, durations.count == times.count, values.count == times.count,
        times.allSatisfy(Self.isSeconds), durations.allSatisfy(Self.isSeconds)
      else {
        self.values = nil
        return
      }
      self.values = times.indices.compactMap { index in
        let valueStart = start + Int((times[index] * 1000).rounded())
        guard Self.counts(valueStart, of: sample) else { return nil }
        return CardReading(
          start: valueStart, end: valueStart + Int((durations[index] * 1000).rounded()),
          value: values[index], source: sample.source, sampleID: sample.sampleID)
      }
    }

    /// Its readings starting in `range`: its values', or its sample's without them.
    public func readings(in range: Range<Int>) -> ArraySlice<CardReading> {
      guard let values else {
        return range.contains(sample.start) ? [sample] : []
      }
      // Values are in order: a slice.
      let lower = values.partitioningIndex { $0.start >= range.lowerBound }
      let upper = values[lower...].partitioningIndex { $0.start >= range.upperBound }
      return values[lower..<upper]
    }
  }

  /// The readings in `range` of `series` (by start): each series' that has any, in their order.
  public static func readings(of series: [Series], in range: Range<Int>)
    -> [ArraySlice<CardReading>]
  {
    let from = starts(for: range).lowerBound
    let first = series.partitioningIndex { $0.sample.start >= from }
    var readings: [ArraySlice<CardReading>] = []
    for series in series[first...] {
      guard series.sample.start < range.upperBound else { break }
      let inRange = series.readings(in: range)
      if !inRange.isEmpty { readings.append(inRange) }
    }
    return readings
  }

  /// Readings of single samples (oldest first, as fetched) with series' readings (each series'
  /// in order, the series by start), oldest first: by start, a single sample before a series'
  /// value starting in the same millisecond, and series' values starting together in their
  /// series' order.
  public static func merged(_ singles: [CardReading], _ series: [ArraySlice<CardReading>])
    -> [CardReading]
  {
    var values: [CardReading] = []
    values.reserveCapacity(series.reduce(0) { $0 + $1.count })
    var inOrder = true
    for readings in series {
      if let last = values.last, let first = readings.first, first.start < last.start {
        inOrder = false
      }
      values += readings
    }
    if !inOrder {
      // Series overlap (two sources', or one's), so their values interleave. A sort by start,
      // then by where each came, keeps the series' order for values starting together.
      values = values.indices
        .sorted { (values[$0].start, $0) < (values[$1].start, $1) }
        .map { values[$0] }
    }
    guard !values.isEmpty else { return singles }
    guard !singles.isEmpty else { return values }
    var merged: [CardReading] = []
    merged.reserveCapacity(singles.count + values.count)
    var (single, value) = (0, 0)
    while single < singles.count, value < values.count {
      if values[value].start < singles[single].start {
        merged.append(values[value])
        value += 1
      } else {
        merged.append(singles[single])
        single += 1
      }
    }
    merged += singles[single...]
    merged += values[value...]
    return merged
  }
}

extension Collection {
  /// The first index whose element is `true` for `belongsInSecondPartition`, in a collection
  /// partitioned by it (every `false` before every `true`): a binary search.
  fileprivate func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Index {
    var low = startIndex
    var count = self.count
    while count > 0 {
      let half = count / 2
      let middle = index(low, offsetBy: half)
      if belongsInSecondPartition(self[middle]) {
        count = half
      } else {
        low = index(after: middle)
        count -= half + 1
      }
    }
    return low
  }
}
