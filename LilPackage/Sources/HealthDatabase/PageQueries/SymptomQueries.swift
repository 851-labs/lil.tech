public import Foundation
public import SQLiteData

extension HealthDatabase {
  static let moodChangesType = "HKCategoryTypeIdentifierMoodChanges"
  static let sleepChangesType = "HKCategoryTypeIdentifierSleepChanges"
  static let appetiteChangesType = "HKCategoryTypeIdentifierAppetiteChanges"

  /// A symptom over the period `offset` periods back (851-2828): for a day, each entry over its
  /// hours at its level; for a week or a month, each day's highest level; for six months or a
  /// year, the days with the symptom in each week or month. Entries start in the period, and
  /// count for the day they start on. Not Present entries (and No Change for appetite) are listed
  /// but not charted or counted. Days split in `calendar`'s time zone.
  public static func symptomChart(
    of typeID: String, range: ChartRange, offset: Int, now: Date, calendar: Calendar,
    _ db: Database
  ) throws -> SymptomChart {
    let interval = range.interval(offset: offset, now: now, calendar: calendar)
    let (lower, upper) = (interval.start.unixMilliseconds, interval.end.unixMilliseconds)
    let entries =
      try HealthSample
      .where { $0.type.eq(typeID) && $0.startDate >= lower && $0.startDate < upper }
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .select { ($0.id, $0.startDate, $0.endDate, $0.categoryValue, $0.sourceName) }
      .fetchAll(db)
      .map { id, start, end, value, source in
        SymptomEntry(
          id: id, typeID: typeID, start: Date(unixMilliseconds: start),
          end: Date(unixMilliseconds: end), value: value, sourceName: source)
      }
    return SymptomChart(
      typeID: typeID, range: range, interval: interval, entries: entries, calendar: calendar)
  }
}

/// How a symptom's values are charted: the levels its bars rise to, from 1.
public enum SymptomScale: Equatable, Sendable {
  /// `HKCategoryValueSeverity`: Present (unspecified), Mild, Moderate, Severe.
  case severity
  /// `HKCategoryValuePresence` (Mood Changes, Sleep Changes): Present.
  case presence
  /// `HKCategoryValueAppetiteChanges`: Present (unspecified), Decreased, Increased.
  case appetite

  public init(typeID: String) {
    switch typeID {
    case HealthDatabase.moodChangesType, HealthDatabase.sleepChangesType: self = .presence
    case HealthDatabase.appetiteChangesType: self = .appetite
    default: self = .severity
    }
  }

  /// Each level's name, from level 1 up.
  public var levels: [String] {
    switch self {
    case .severity: ["Present", "Mild", "Moderate", "Severe"]
    case .presence: ["Present"]
    case .appetite: ["Present", "Decreased", "Increased"]
    }
  }

  /// The level a value is charted at, from 1: nil for Not Present (No Change for appetite), which
  /// is 1 in each kind. Present (unspecified, 0) is 1, as is a value Health doesn't have yet, as
  /// it reads "Present".
  public func level(_ value: Int?) -> Int? {
    switch (self, value) {
    case (_, 1): nil
    case (.severity, .some(let value)) where (2...4).contains(value): value
    case (.appetite, .some(let value)) where (2...3).contains(value): value
    default: 1
    }
  }
}

/// One logged symptom: when, at what level, and from where.
public struct SymptomEntry: Equatable, Identifiable, Sendable {
  public var id: String
  public var start: Date
  public var end: Date
  /// HealthKit's raw value (`HKCategoryValueSeverity`, `…Presence`, `…AppetiteChanges`).
  public var value: Int?
  /// The value as Health names it ("Moderate"), "Present" for one it doesn't name.
  public var name: String
  /// Where it's charted, from 1; nil when it isn't (Not Present).
  public var level: Int?
  public var sourceName: String

  public init(
    id: String, typeID: String, start: Date, end: Date, value: Int?, sourceName: String
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.value = value
    name = HealthDatabase.categoryValueName(value, typeID: typeID) ?? "Present"
    level = SymptomScale(typeID: typeID).level(value)
    self.sourceName = sourceName
  }
}

/// A bar: an entry (a day), a day's highest level (a week or a month), or a week's or month's
/// days with the symptom (six months or a year).
public struct SymptomPoint: Equatable, Sendable {
  public var start: Date
  /// An entry's end, within the period, or the end of the bar's day, week or month.
  public var end: Date
  /// The bar's height: a level (D, W, M) or a number of days (6M, Y).
  public var value: Int
  /// The entries it charts, oldest first.
  public var entries: [SymptomEntry]

  public init(start: Date, end: Date, value: Int, entries: [SymptomEntry]) {
    self.start = start
    self.end = end
    self.value = value
    self.entries = entries
  }
}

/// A period of a symptom: its bars, its entries (newest first) and the days it was present.
public struct SymptomChart: Equatable, Sendable {
  public var range: ChartRange
  public var interval: DateInterval
  public var scale: SymptomScale
  public var points: [SymptomPoint]
  public var entries: [SymptomEntry]
  /// Days in the period with the symptom present, for the header.
  public var days: Int

  public init(
    range: ChartRange, interval: DateInterval, scale: SymptomScale, points: [SymptomPoint],
    entries: [SymptomEntry], days: Int
  ) {
    self.range = range
    self.interval = interval
    self.scale = scale
    self.points = points
    self.entries = entries
    self.days = days
  }

  /// The chart of `entries` (newest first) over `interval`, as `symptomChart` makes it.
  public init(
    typeID: String, range: ChartRange, interval: DateInterval, entries: [SymptomEntry],
    calendar: Calendar
  ) {
    let present = entries.reversed().filter { $0.level != nil }
    func start(of unit: Calendar.Component, _ date: Date) -> DateInterval {
      calendar.dateInterval(of: unit, for: date) ?? DateInterval(start: date, duration: 0)
    }
    var byDay: [Date: [SymptomEntry]] = [:]
    for entry in present {
      byDay[start(of: .day, entry.start).start, default: []].append(entry)
    }
    let points: [SymptomPoint]
    switch range {
    case .day:
      points = present.map { entry in
        SymptomPoint(
          start: entry.start, end: min(max(entry.end, entry.start), interval.end),
          value: entry.level ?? 0, entries: [entry])
      }
    case .week, .month:
      points = byDay.sorted { $0.key < $1.key }.map { day, entries in
        SymptomPoint(
          start: day, end: start(of: .day, day).end,
          value: entries.compactMap(\.level).max() ?? 0, entries: entries)
      }
    case .sixMonths, .year:
      var buckets: [Date: (days: Int, entries: [SymptomEntry])] = [:]
      for (day, entries) in byDay {
        let bucket = start(of: range.barUnit, day).start
        buckets[bucket, default: (0, [])].days += 1
        buckets[bucket, default: (0, [])].entries += entries
      }
      points = buckets.sorted { $0.key < $1.key }.map { bucket, value in
        SymptomPoint(
          start: bucket, end: start(of: range.barUnit, bucket).end, value: value.days,
          entries: value.entries.sorted { $0.start < $1.start })
      }
    }
    self.init(
      range: range, interval: interval, scale: SymptomScale(typeID: typeID), points: points,
      entries: entries, days: byDay.count)
  }
}
