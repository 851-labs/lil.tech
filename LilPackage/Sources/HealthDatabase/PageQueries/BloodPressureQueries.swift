public import Foundation
public import SQLiteData

extension HealthDatabase {
  public static let bloodPressureType = "HKCorrelationTypeIdentifierBloodPressure"
  static let systolicType = "HKQuantityTypeIdentifierBloodPressureSystolic"
  static let diastolicType = "HKQuantityTypeIdentifierBloodPressureDiastolic"

  /// Blood pressure readings starting in `interval`, newest first: each correlation with its
  /// systolic and diastolic samples, joined by `correlationID`. A reading missing one value still
  /// counts.
  public static func bloodPressureReadings(
    in interval: DateInterval, _ db: Database
  ) throws -> [BloodPressureReading] {
    let (lower, upper) = (interval.start.unixMilliseconds, interval.end.unixMilliseconds)
    let correlations =
      try HealthCorrelation
      .where { $0.type.eq(bloodPressureType) && $0.startDate >= lower && $0.startDate < upper }
      .order { $0.startDate.desc() }
      .fetchAll(db)
    guard !correlations.isEmpty else { return [] }
    let ids = correlations.map(\.id)
    let samples =
      try HealthSample
      .where {
        $0.correlationID.in(ids.map(Optional.some)) && $0.type.in([systolicType, diastolicType])
      }
      .select { ($0.correlationID, $0.type, $0.value) }
      .fetchAll(db)
    var values: [String: (systolic: Double?, diastolic: Double?)] = [:]
    for (correlation, type, value) in samples {
      guard let correlation else { continue }
      if type == systolicType {
        values[correlation, default: (nil, nil)].systolic = value
      } else {
        values[correlation, default: (nil, nil)].diastolic = value
      }
    }
    return correlations.map { correlation in
      BloodPressureReading(
        id: correlation.id, date: Date(unixMilliseconds: correlation.startDate),
        systolic: values[correlation.id]?.systolic, diastolic: values[correlation.id]?.diastolic,
        sourceName: correlation.sourceName)
    }
  }

  /// Blood pressure over the period `offset` periods back: for a day or a week, each reading; for
  /// longer ones, each day's, week's or month's range of each value. With the period's average
  /// and range for the header.
  public static func bloodPressureChart(
    range: ChartRange, offset: Int, now: Date, calendar: Calendar, _ db: Database
  ) throws -> BloodPressureChart {
    let interval = range.interval(offset: offset, now: now, calendar: calendar)
    let readings = try bloodPressureReadings(in: interval, db)
    let points: [BloodPressurePoint]
    if range == .day || range == .week {
      points = readings.reversed().map { reading in
        BloodPressurePoint(
          start: reading.date, systolic: reading.systolic.map { $0...$0 },
          diastolic: reading.diastolic.map { $0...$0 }, readings: [reading])
      }
    } else {
      var buckets: [Date: [BloodPressureReading]] = [:]
      for reading in readings {
        let start =
          calendar.dateInterval(of: range.barUnit, for: reading.date)?.start ?? reading.date
        buckets[start, default: []].append(reading)
      }
      points = buckets.sorted { $0.key < $1.key }.map { start, readings in
        BloodPressurePoint(
          start: start, systolic: span(readings.compactMap(\.systolic)),
          diastolic: span(readings.compactMap(\.diastolic)), readings: readings)
      }
    }
    return BloodPressureChart(interval: interval, points: points, readings: readings)
  }

  private static func span(_ values: [Double]) -> ClosedRange<Double>? {
    guard let low = values.min(), let high = values.max() else { return nil }
    return low...high
  }
}

/// One reading: systolic over diastolic, either of which may be missing.
public struct BloodPressureReading: Equatable, Identifiable, Sendable {
  public var id: String
  public var date: Date
  public var systolic: Double?
  public var diastolic: Double?
  public var sourceName: String

  public init(
    id: String, date: Date, systolic: Double?, diastolic: Double?, sourceName: String
  ) {
    self.id = id
    self.date = date
    self.systolic = systolic
    self.diastolic = diastolic
    self.sourceName = sourceName
  }
}

/// A bar: one reading (a day or a week), or a bucket's range of each value.
public struct BloodPressurePoint: Equatable, Sendable {
  public var start: Date
  public var systolic: ClosedRange<Double>?
  public var diastolic: ClosedRange<Double>?
  public var readings: [BloodPressureReading]

  public init(
    start: Date, systolic: ClosedRange<Double>?, diastolic: ClosedRange<Double>?,
    readings: [BloodPressureReading]
  ) {
    self.start = start
    self.systolic = systolic
    self.diastolic = diastolic
    self.readings = readings
  }
}

/// A period of blood pressure: its bars and its readings, newest first.
public struct BloodPressureChart: Equatable, Sendable {
  public var interval: DateInterval
  public var points: [BloodPressurePoint]
  public var readings: [BloodPressureReading]

  public init(
    interval: DateInterval, points: [BloodPressurePoint], readings: [BloodPressureReading]
  ) {
    self.interval = interval
    self.points = points
    self.readings = readings
  }

  /// The period's average of each value, among readings that have it.
  public var average: (systolic: Double, diastolic: Double)? {
    let systolic = readings.compactMap(\.systolic)
    let diastolic = readings.compactMap(\.diastolic)
    guard !systolic.isEmpty || !diastolic.isEmpty else { return nil }
    func mean(_ values: [Double]) -> Double {
      values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    return (mean(systolic), mean(diastolic))
  }

  /// The period's lowest and highest of each value.
  public var span: (systolic: ClosedRange<Double>?, diastolic: ClosedRange<Double>?) {
    func range(_ values: [Double]) -> ClosedRange<Double>? {
      guard let low = values.min(), let high = values.max() else { return nil }
      return low...high
    }
    return (range(readings.compactMap(\.systolic)), range(readings.compactMap(\.diastolic)))
  }
}
