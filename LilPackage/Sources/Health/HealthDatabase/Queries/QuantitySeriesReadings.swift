public import Foundation
import GRDB
public import HealthCards
public import SQLiteData

// Quantity series as readings (851-4171): a sample whose `count` is over 1 (a Watch's heart rate
// in a workout) keeps its values in `healthQuantitySeries` (851-4149), and statistics read each
// value as a reading of its own, at its own time, as HealthKit's statistics split a series. The
// server's `tools/HealthQueries.ts` reads them by the same rules (`quantityReadings`), and the
// cards' engines can share them (851-4172).

/// A quantity series' values, from its `healthQuantitySeries` row's JSON arrays: each value's
/// start and duration in seconds since the sample's start, and the value in the type's unit.
public struct QuantitySeriesValues: Equatable, Sendable {
  public var times: [Double]
  public var durations: [Double]
  public var values: [Double]

  public init(times: [Double], durations: [Double], values: [Double]) {
    self.times = times
    self.durations = durations
    self.values = values
  }

  /// `nil` when the iPhone didn't upload the values (more than `HealthEncoder.maxSeriesValues`),
  /// or they don't decode as one entry each.
  public init?(times: String?, durations: String?, values: String?) {
    guard let times, let durations, let values else { return nil }
    let decoder = JSONDecoder()
    guard
      let times = try? decoder.decode([Double].self, from: Data(times.utf8)),
      let durations = try? decoder.decode([Double].self, from: Data(durations.utf8)),
      let values = try? decoder.decode([Double].self, from: Data(values.utf8)),
      durations.count == times.count, values.count == times.count
    else { return nil }
    self.init(times: times, durations: durations, values: values)
  }

  /// When value `index` starts and ends, in Unix milliseconds, for a sample starting at `start`:
  /// its seconds rounded to the millisecond, as the server rounds them.
  public func interval(at index: Int, sampleStart start: Int) -> (start: Int, end: Int) {
    let from = start + Int((times[index] * 1000).rounded())
    return (from, from + Int((durations[index] * 1000).rounded()))
  }
}

/// A sample that's a quantity series, with what statistics need of it.
public struct QuantitySeriesSample: Equatable, Sendable {
  public var id: String
  /// Unix milliseconds.
  public var start: Int
  public var end: Int
  /// HealthKit's value for the whole series: its total, or its (time-weighted) average.
  public var value: Double?
  public var source: String
  /// `nil` when they weren't uploaded.
  public var values: QuantitySeriesValues?
  /// A discrete series' lowest and highest values.
  public var minimum: Double?
  public var maximum: Double?

  /// One reading per value, in order, of those that start by the sample's end and less than
  /// `seriesLookback` after its start; or, without its values, one for the sample, at its start
  /// (none without a value either).
  public var readings: [CardReading] {
    guard let values else {
      return value.map {
        [CardReading(start: start, end: end, value: $0, source: source, sampleID: id)]
      } ?? []
    }
    let reach = start + HealthDatabase.seriesLookbackMilliseconds
    return values.values.indices.compactMap { index in
      let interval = values.interval(at: index, sampleStart: start)
      guard interval.start <= end, interval.start < reach else { return nil }
      return CardReading(
        start: interval.start, end: interval.end, value: values.values[index], source: source,
        sampleID: id)
    }
  }
}

/// A quantity type's readings, oldest first, with a series' values as readings of their own.
public struct QuantityReadings: Equatable, Sendable {
  public var readings: [CardReading]
  /// The lowest and highest value of readings that stand for a series without its values, by
  /// index in `readings`: its own `minimum` and `maximum`, which minimums and maximums take.
  public var extremes: [Int: ClosedRange<Double>]

  public init(readings: [CardReading], extremes: [Int: ClosedRange<Double>] = [:]) {
    self.readings = readings
    self.extremes = extremes
  }

  /// Reading `index`'s lowest and highest value.
  public func range(at index: Int) -> ClosedRange<Double> {
    extremes[index] ?? readings[index].value...readings[index].value
  }
}

extension HealthDatabase {
  /// How long after its start a series' values count. A series' values count where they fall,
  /// so a range reads the series that started this long before it too; values later than that
  /// (or after the sample's end) don't count anywhere, so what a range reads doesn't depend on
  /// where it starts. The iPhone uploads at most 20,000 values a series
  /// (`HealthEncoder.maxSeriesValues`): a week of them every 30 s.
  public static let seriesLookback: TimeInterval = 7 * 86_400

  static let seriesLookbackMilliseconds = Int(seriesLookback * 1000)

  /// A type's series whose samples start in `[from, to)` (Unix milliseconds) and end at or after
  /// `endingFrom`, oldest first, then by ID. Through the series' own (type, startDate) index, so
  /// a range without series costs a seek.
  public static func quantitySeries(
    of type: String, from: Int, to: Int, endingFrom: Int = .min, _ db: Database
  ) throws -> [QuantitySeriesSample] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT "s"."id", "s"."startDate", "s"."endDate", "s"."value", "s"."sourceBundleID",
          "q"."times", "q"."durations", "q"."values", "q"."minimum", "q"."maximum"
        FROM "healthQuantitySeries" AS "q" JOIN "healthSamples" AS "s" ON "s"."id" = "q"."id"
        WHERE "q"."type" = ? AND "q"."startDate" >= ? AND "q"."startDate" < ?
          AND "s"."endDate" >= ?
        ORDER BY "q"."startDate", "q"."id"
        """,
      arguments: [type, from, to, endingFrom]
    )
    .map { row in
      QuantitySeriesSample(
        id: row["id"], start: row["startDate"], end: row["endDate"], value: row["value"],
        source: row["sourceBundleID"],
        values: QuantitySeriesValues(
          times: row["times"], durations: row["durations"], values: row["values"]),
        minimum: row["minimum"], maximum: row["maximum"])
    }
  }

  /// A quantity type's readings that start in `[from, to)` (Unix milliseconds), oldest first:
  /// each sample with a value, except that a series is one reading per value, at the value's
  /// own time (`QuantitySeriesSample.readings`), of the series that started up to
  /// `seriesLookback` before `from` too. A series without its values stays one reading, at its
  /// start, whose extremes are the series'.
  /// Readings that start together keep single samples first, then series by start, ID and
  /// value, as the server's `quantityReadings` orders them.
  public static func quantityReadings(
    of type: String, from: Int, to: Int, _ db: Database
  ) throws -> QuantityReadings {
    let series = try quantitySeries(
      of: type, from: from - seriesLookbackMilliseconds, to: to, endingFrom: from, db)
    let seriesIDs = Set(series.lazy.filter { $0.start >= from }.map(\.id))
    var singles: [CardReading] = []
    if seriesIDs.isEmpty {
      singles =
        try HealthSample
        .where { $0.type.eq(type) && $0.startDate >= from && $0.startDate < to }
        .order(by: \.startDate)
        .select { ($0.startDate, $0.endDate, $0.value, $0.sourceBundleID) }
        .fetchAll(db)
        .compactMap { start, end, value, source in
          value.map { CardReading(start: start, end: end, value: $0, source: source) }
        }
    } else {
      singles =
        try HealthSample
        .where { $0.type.eq(type) && $0.startDate >= from && $0.startDate < to }
        .order(by: \.startDate)
        .select { ($0.startDate, $0.endDate, $0.value, $0.sourceBundleID, $0.id) }
        .fetchAll(db)
        .compactMap { start, end, value, source, id in
          guard !seriesIDs.contains(id) else { return nil }
          return value.map { CardReading(start: start, end: end, value: $0, source: source) }
        }
    }
    guard !series.isEmpty else { return QuantityReadings(readings: singles) }

    // Every series' readings in range, by start, then the series' order, then their own.
    var values: [(reading: CardReading, extremes: ClosedRange<Double>?)] = []
    for sample in series {
      let extremes: ClosedRange<Double>? =
        sample.values == nil
        ? sample.minimum.flatMap { minimum in sample.maximum.map { minimum...max(minimum, $0) } }
        : nil
      for reading in sample.readings where reading.start >= from && reading.start < to {
        values.append((reading, extremes))
      }
    }
    let order = values.indices.sorted {
      (values[$0].reading.start, $0) < (values[$1].reading.start, $1)
    }

    var merged = QuantityReadings(readings: [])
    merged.readings.reserveCapacity(singles.count + values.count)
    var single = 0
    for index in order {
      let (reading, extremes) = values[index]
      while single < singles.count, singles[single].start <= reading.start {
        merged.readings.append(singles[single])
        single += 1
      }
      if let extremes { merged.extremes[merged.readings.count] = extremes }
      merged.readings.append(reading)
    }
    merged.readings.append(contentsOf: singles[single...])
    return merged
  }
}
