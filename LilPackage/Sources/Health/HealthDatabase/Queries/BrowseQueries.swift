public import Foundation
public import HealthCatalog
public import SQLiteData

/// What Browse shows for one data type: its latest value, and the days before it.
public struct MetricSummary: Equatable, Identifiable, Sendable {
  /// The data type's ID.
  public let id: String
  /// When the latest data is from: a cumulative type's latest day, otherwise its latest record.
  /// `nil` without any data.
  public var latestDate: Date?
  /// The latest value in `unit`: a cumulative type's total that day, a discrete type's latest
  /// sample. `nil` for types without a single value (e.g. symptoms, workouts).
  public var latestValue: Double?
  public var unit: String?
  /// Whether `latestDate` is a whole day (a total) rather than a moment.
  public var isDailyTotal: Bool
  /// One value a day for the week ending on the latest day, oldest first: totals for cumulative
  /// types, averages for discrete ones, with their lowest and highest readings for range charts.
  /// Days without data are left out.
  public var days: [DailyValue]
  /// Whether it has data without a date: medications shared before any of their doses are
  /// logged, since a medication's date is its latest dose's.
  public var hasUndatedData: Bool
  /// For sound levels, the exposure of the week `days` covers, which Health's rows show in
  /// place of the latest value (851-3100). `nil` for other types, or without data.
  public var soundExposure: SoundExposure?

  public init(
    id: String, latestDate: Date? = nil, latestValue: Double? = nil, unit: String? = nil,
    isDailyTotal: Bool = false, days: [DailyValue] = [], hasUndatedData: Bool = false,
    soundExposure: SoundExposure? = nil
  ) {
    self.id = id
    self.latestDate = latestDate
    self.latestValue = latestValue
    self.unit = unit
    self.isDailyTotal = isDailyTotal
    self.days = days
    self.hasUndatedData = hasUndatedData
    self.soundExposure = soundExposure
  }

  public var hasData: Bool { latestDate != nil || hasUndatedData }
}

public struct DailyValue: Equatable, Sendable {
  public var day: Date
  public var value: Double
  /// A discrete type's lowest and highest values that day, for range bars. `nil` for totals.
  public var minimum: Double?
  public var maximum: Double?

  public init(day: Date, value: Double, minimum: Double? = nil, maximum: Double? = nil) {
    self.day = day
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
  }
}

extension HealthDatabase {
  /// Days a summary's chart covers, ending on the latest day.
  static let summaryDays = 7

  /// Summaries of every type Browse lists under `category`, in the catalog's order.
  public static func metricSummaries(
    in category: HealthCategory, now: Date, calendar: Calendar, _ db: Database
  ) throws -> [MetricSummary] {
    try HealthCatalog.types(in: category).map {
      try metricSummary(of: $0, now: now, calendar: calendar, db)
    }
  }

  /// A type's latest value and the week ending on it.
  public static func metricSummary(
    of type: HealthDataType, now: Date, calendar: Calendar, _ db: Database
  ) throws -> MetricSummary {
    switch type.kind {
    case .quantity where type.aggregation?.isCumulative == true:
      return try cumulativeSummary(of: type, now: now, calendar: calendar, db)
    case .quantity:
      return try discreteSummary(of: type, calendar: calendar, db)
    case .medication:
      // A medication without doses is still data, an as-needed one never logged included.
      let latestDate = try latestDate(of: type, calendar: calendar, db)
      let hasMedications =
        try latestDate == nil && HealthMedication.select(\.id).limit(1).fetchOne(db) != nil
      return MetricSummary(id: type.id, latestDate: latestDate, hasUndatedData: hasMedications)
    default:
      return MetricSummary(
        id: type.id, latestDate: try latestDate(of: type, calendar: calendar, db),
        // Activity rings are a day's.
        isDailyTotal: type.kind == .activitySummary)
    }
  }

  /// The latest day's total, from the statistics source's buckets. Days the buckets don't cover
  /// yet (none at all, or the latest sample's day before its buckets arrive) use the samples'
  /// own total, which counts overlapping sources twice where HealthKit's statistics wouldn't.
  private static func cumulativeSummary(
    of type: HealthDataType, now: Date, calendar: Calendar, _ db: Database
  ) throws -> MetricSummary {
    guard let latest = try latestCumulativeStart(of: type.id, now: now, db) else {
      return MetricSummary(id: type.id)
    }
    let latestDay = calendar.startOfDay(for: latest)
    let week = weekEnding(on: latestDay, calendar: calendar)
    var days = try cumulativeStatistics(
      of: type.id, in: week, by: .day, calendar: calendar, now: now, db
    )
    .map { DailyValue(day: $0.start, value: $0.sum) }
    if days.last?.day != latestDay {
      // From the latest day only, unless there are no statistics at all.
      let lower = (days.isEmpty ? week.lowerBound : latestDay).unixMilliseconds
      let upper = week.upperBound.unixMilliseconds
      let samples =
        try HealthSample
        .where { $0.type.eq(type.id) && $0.startDate >= lower && $0.startDate < upper }
        .select { ($0.startDate, $0.value) }
        .fetchAll(db)
      var totals: [Date: Double] = [:]
      for (start, value) in samples {
        totals[calendar.startOfDay(for: Date(unixMilliseconds: start)), default: 0] += value ?? 0
      }
      days += totals.sorted { $0.key < $1.key }.map { DailyValue(day: $0.key, value: $0.value) }
    }
    return MetricSummary(
      id: type.id, latestDate: latestDay, latestValue: days.last { $0.day == latestDay }?.value,
      unit: type.unit, isDailyTotal: true, days: days)
  }

  /// When a cumulative type's latest data started: its latest bucket with anything in it, from
  /// the statistics source, or its latest sample, whichever is later, of those started by `now`.
  static func latestCumulativeStart(of typeID: String, now: Date, _ db: Database) throws -> Date? {
    let source = try statisticsSource(db, now: now)
    // The iPhone sends empty buckets up to a day ahead (to overwrite sums that are gone), so the
    // latest day is the latest with anything in it that has started.
    let started = now.unixMilliseconds
    let latestBucket = try source.flatMap { source in
      try HealthStatistic
        .where {
          $0.device.eq(source) && $0.type.eq(typeID) && $0.sum > 0 && $0.bucketStart <= started
        }
        .order { $0.bucketStart.desc() }
        .select(\.bucketStart)
        .limit(1)
        .fetchOne(db)
    }
    // Not a sample logged ahead, e.g. tomorrow's planned meal.
    let latestSample = try latestSample(of: typeID, startedBy: now, db)
    return [latestBucket, latestSample?.startDate].compactMap { $0 }.max()
      .map(Date.init(unixMilliseconds:))
  }

  /// The latest sample, and daily averages and ranges for the week ending on its day. Sound
  /// levels add that week's exposure.
  private static func discreteSummary(
    of type: HealthDataType, calendar: Calendar, _ db: Database
  ) throws -> MetricSummary {
    guard let latest = try latestSample(of: type.id, db) else { return MetricSummary(id: type.id) }
    let date = Date(unixMilliseconds: latest.startDate)
    let week = weekEnding(on: calendar.startOfDay(for: date), calendar: calendar)
    let days = try discreteStatistics(of: type.id, in: week, by: .day, calendar: calendar, db)
      .map {
        DailyValue(day: $0.start, value: $0.average, minimum: $0.minimum, maximum: $0.maximum)
      }
    let exposure =
      soundLevelTypes.contains(type.id) ? try soundExposure(of: type.id, in: week, db) : nil
    return MetricSummary(
      id: type.id, latestDate: date, latestValue: latest.value, unit: latest.unit ?? type.unit,
      days: days, soundExposure: exposure)
  }

  /// When a type without a single value was last recorded, from wherever it's stored. `nil` for
  /// types that aren't synced yet.
  private static func latestDate(
    of type: HealthDataType, calendar: Calendar, _ db: Database
  ) throws -> Date? {
    let milliseconds: Int?
    switch type.kind {
    case .category:
      milliseconds = try latestSample(of: type.id, db)?.startDate
    case .correlation:
      milliseconds =
        try HealthCorrelation.where { $0.type.eq(type.id) }
        .order { $0.startDate.desc() }.select(\.startDate).limit(1).fetchOne(db)
    case .workout:
      milliseconds =
        try HealthWorkout.order { $0.startDate.desc() }.select(\.startDate).limit(1).fetchOne(db)
    case .workoutRoute:
      milliseconds =
        try HealthWorkoutRoute.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .stateOfMind:
      milliseconds =
        try HealthStateOfMind.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .scoredAssessment:
      milliseconds =
        try HealthScoredAssessment.where { $0.type.eq(type.id) }
        .order { $0.startDate.desc() }.select(\.startDate).limit(1).fetchOne(db)
    case .audiogram:
      milliseconds =
        try HealthAudiogram.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .visionPrescription:
      milliseconds =
        try HealthVisionPrescription.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .medication, .medicationDoseEvent:
      // A medication's latest date is its latest dose's.
      milliseconds =
        try HealthMedicationDose.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .electrocardiogram:
      milliseconds =
        try HealthElectrocardiogram.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .heartbeatSeries:
      milliseconds =
        try HealthHeartbeatSeries.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .activitySummary:
      // Keyed by their day, `yyyy-MM-dd`, which sorts by date.
      let day = try HealthActivitySummary.order { $0.id.desc() }.select(\.id).limit(1)
        .fetchOne(db)
      return day.flatMap { gregorianDay($0, calendar: calendar) }
    case .document:
      milliseconds =
        try HealthDocument.order { $0.startDate.desc() }.select(\.startDate).limit(1)
        .fetchOne(db)
    case .quantity, .characteristic:
      milliseconds = nil
    }
    return milliseconds.map(Date.init(unixMilliseconds:))
  }

  /// The start of a `yyyy-MM-dd` day in `calendar`'s time zone.
  static func gregorianDay(_ id: String, calendar: Calendar) -> Date? {
    let parts = id.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  /// The `summaryDays` days ending with `day` (a start of day): the week a summary's `days`
  /// cover, which the rows' sparklines span.
  public static func weekEnding(on day: Date, calendar: Calendar) -> Range<Date> {
    let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
    let start = calendar.date(byAdding: .day, value: 1 - summaryDays, to: day) ?? day
    return start..<end
  }
}
