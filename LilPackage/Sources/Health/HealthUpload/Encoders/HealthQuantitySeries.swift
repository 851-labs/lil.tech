public import Foundation
import HealthKit

/// A quantity series' contents (851-4149): a quantity sample whose `count` is over 1, such as a
/// Watch's heart rate during a workout or an app's steps written with
/// `HKQuantitySeriesSampleBuilder`. Read out of the sample and its values' query, so the encoding
/// can be tested without HealthKit.
public struct QuantitySeriesRecord: Equatable, Sendable {
  public var id: UUID
  public var type: String
  public var start: Date
  /// `HKQuantitySample.count`.
  public var count: Int
  /// Each value with its interval, in time order, in the type's catalog unit; `nil` when they
  /// weren't read: more than `HealthEncoder.maxSeriesValues`.
  public var values: [Value]?
  /// A discrete series' lowest, highest and most recent value; `nil` for a cumulative one.
  public var summary: Summary?

  public struct Value: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var value: Double

    public init(start: Date, end: Date, value: Double) {
      self.start = start
      self.end = end
      self.value = value
    }
  }

  public struct Summary: Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var mostRecent: Double
    public var mostRecentStart: Date
    public var mostRecentEnd: Date

    public init(
      minimum: Double, maximum: Double, mostRecent: Double, mostRecentStart: Date,
      mostRecentEnd: Date
    ) {
      self.minimum = minimum
      self.maximum = maximum
      self.mostRecent = mostRecent
      self.mostRecentStart = mostRecentStart
      self.mostRecentEnd = mostRecentEnd
    }
  }

  public init(
    id: UUID, type: String, start: Date, count: Int, values: [Value]?, summary: Summary?
  ) {
    self.id = id
    self.type = type
    self.start = start
    self.count = count
    self.values = values
    self.summary = summary
  }
}

extension QuantitySeriesRecord {
  /// A series sample's record, with `values` as read (`HealthReader.seriesValues`), or `nil` when
  /// it has too many to read.
  init(_ sample: HKQuantitySample, values: [Value]?) throws {
    let unit = try HealthEncoder.unit(for: sample.quantityType)
    self.init(
      id: sample.uuid, type: sample.quantityType.identifier, start: sample.startDate,
      count: sample.count, values: values?.sorted { ($0.start, $0.end) < ($1.start, $1.end) },
      summary: (sample as? HKDiscreteQuantitySample).map { discrete in
        Summary(
          minimum: discrete.minimumQuantity.doubleValue(for: unit),
          maximum: discrete.maximumQuantity.doubleValue(for: unit),
          mostRecent: discrete.mostRecentQuantity.doubleValue(for: unit),
          mostRecentStart: discrete.mostRecentQuantityDateInterval.start,
          mostRecentEnd: discrete.mostRecentQuantityDateInterval.end)
      })
  }
}

extension HealthEncoder {
  public static let quantitySeriesEntity = "health_quantity_series"

  /// The most values a series uploads with (851-4149). Each is at most about 40 bytes of JSON
  /// (its start, duration and value), so a line stays well under the server's 1 MB. A series with
  /// more, say an app's all-day series at 1 Hz, goes up with its count and summary only, and
  /// counts as one value, as every series did before.
  public static let maxSeriesValues = 20_000

  /// How the iPhone's quantity samples are read (`HealthBackfillState.quantitySeriesEncoding`).
  /// 1: series samples go up with their values (851-4149).
  public static let quantitySeriesEncoding = 1

  /// Whether a quantity sample is a series, whose values go up as a `health_quantity_series`
  /// record beside it.
  static func isSeries(_ sample: HKQuantitySample) -> Bool { sample.count > 1 }

  /// A quantity series (`HealthQuantitySeries` on the server): each value's start and duration
  /// in seconds since the sample's start, as milliseconds apart as the server stores times, and
  /// its value.
  public static func quantitySeries(_ series: QuantitySeriesRecord) -> HealthMutation {
    let start = milliseconds(series.start)
    var row: [String: JSONValue] = [
      "type": .string(series.type),
      "startDate": .number(start),
      "count": .number(Double(series.count)),
      "times": .null, "durations": .null, "values": .null,
      "minimum": .null, "maximum": .null, "mostRecent": .null,
      "mostRecentStartDate": .null, "mostRecentEndDate": .null,
    ]
    if let values = series.values {
      // HealthKit keeps a series' values within its sample, so none starts before it; but a time
      // can't be negative on the server, whatever the rounding.
      row["times"] = .array(
        values.map { .number(max(0, milliseconds($0.start) - start) / 1000) })
      row["durations"] = .array(
        values.map { .number(max(0, milliseconds($0.end) - milliseconds($0.start)) / 1000) })
      row["values"] = .array(values.map { .number(significant($0.value)) })
    }
    if let summary = series.summary {
      row["minimum"] = .number(summary.minimum)
      row["maximum"] = .number(summary.maximum)
      row["mostRecent"] = .number(summary.mostRecent)
      row["mostRecentStartDate"] = .number(milliseconds(summary.mostRecentStart))
      row["mostRecentEndDate"] = .number(milliseconds(summary.mostRecentEnd))
    }
    return .upsert(quantitySeriesEntity, id: id(series.id), row: row)
  }

  /// A value to 12 significant digits, far finer than any sensor measures: a value read back in
  /// another unit than it was saved in comes with conversion noise (`125.00000000000001` count/min
  /// for 125), which would make each of a series' values 18 characters of JSON. Dividing a whole
  /// number by an exact power of ten gives the double nearest the decimal, which JSON writes
  /// shortest (`0.3048`). Values too small or large for that, and 0, stay as they are.
  static func significant(_ value: Double) -> Double {
    guard value.isFinite, value != 0 else { return value }
    let exponent = 11 - Int(log10(abs(value)).rounded(.down))
    guard (-22...22).contains(exponent) else { return value }
    let scale = pow(10, Double(abs(exponent)))
    return exponent >= 0
      ? (value * scale).rounded() / scale : (value / scale).rounded() * scale
  }
}
