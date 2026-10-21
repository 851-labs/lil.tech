public import Foundation
public import SQLiteData

extension HealthDatabase {
  static let moodChangesType = "HKCategoryTypeIdentifierMoodChanges"
  static let sleepChangesType = "HKCategoryTypeIdentifierSleepChanges"
  static let appetiteChangesType = "HKCategoryTypeIdentifierAppetiteChanges"

  /// How far back an entry that runs into a period may start: symptoms are logged for moments,
  /// hours or a few days, so a week bounds the indexed search on the start.
  static let symptomLookback = 7 * 86_400_000

  /// A symptom over the period `offset` periods back (851-2828): for a day, each entry over its
  /// hours at its level; for a week or a month, each day's highest level (each level a day has,
  /// for appetite, whose levels aren't ordered); for six months or a year, the days with the
  /// symptom in each week or month. Entries overlap the period, starting in it or up to
  /// `symptomLookback` before it, and count for every day they cover in it. Not Present entries
  /// (No Change for appetite) are listed but not charted or counted. Days split in `calendar`'s
  /// time zone.
  public static func symptomChart(
    of typeID: String, range: ChartRange, offset: Int, now: Date, calendar: Calendar,
    _ db: Database
  ) throws -> SymptomChart {
    let interval = range.interval(offset: offset, now: now, calendar: calendar)
    let (lower, upper) = (interval.start.unixMilliseconds, interval.end.unixMilliseconds)
    let earliest = lower - symptomLookback
    let entries =
      try HealthSample
      .where {
        $0.type.eq(typeID) && $0.startDate >= earliest && $0.startDate < upper
          && ($0.startDate >= lower || $0.endDate > lower)
      }
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

/// How a symptom's values are named and charted: the levels its marks are at, from 1. The one
/// source for Show All Data, Cycle Tracking and the symptom page.
public enum SymptomScale: Equatable, Sendable {
  /// `HKCategoryValueSeverity`: Present (unspecified), Mild, Moderate, Severe.
  case severity
  /// `HKCategoryValuePresence` (Mood Changes, Sleep Changes): Present.
  case presence
  /// `HKCategoryValueAppetiteChanges`: Present (unspecified), Decreased, Increased. Kinds of
  /// change, not an order.
  case appetite

  /// The scale of one of Health's Symptoms; nil for other types.
  public init?(typeID: String) {
    switch typeID {
    case HealthDatabase.moodChangesType, HealthDatabase.sleepChangesType: self = .presence
    case HealthDatabase.appetiteChangesType: self = .appetite
    case _ where HealthDatabase.symptomTypes.contains(typeID): self = .severity
    default: return nil
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

  /// Whether a higher level is more of the symptom, so a day's highest stands for it. Appetite's
  /// aren't: its levels are categories, each charted in its own row.
  public var isOrdered: Bool { self != .appetite }

  /// The level a value is charted at, from 1: nil for Not Present (No Change for appetite), which
  /// is 1 in each kind. Present (unspecified, 0) is 1, as is a value Health doesn't have yet (or
  /// none), as it reads "Present".
  public func level(_ value: Int?) -> Int? {
    switch (self, value) {
    case (_, 1): nil
    case (.severity, .some(let value)) where (2...4).contains(value): value
    case (.appetite, .some(let value)) where (2...3).contains(value): value
    default: 1
    }
  }

  /// A value as Health names it: "Moderate", "Not Present", "No Change"; "Present" for one it
  /// doesn't name.
  public func name(_ value: Int?) -> String {
    guard let level = level(value) else { return self == .appetite ? "No Change" : "Not Present" }
    return levels[level - 1]
  }
}

/// One logged symptom: when, at what level, and from where.
public struct SymptomEntry: Equatable, Identifiable, Sendable {
  public var id: String
  public var start: Date
  public var end: Date
  /// HealthKit's raw value (`HKCategoryValueSeverity`, `…Presence`, `…AppetiteChanges`).
  public var value: Int?
  /// The value as Health names it ("Moderate"), "Present" for one it doesn't name
  /// (`SymptomScale.name`).
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
    let scale = SymptomScale(typeID: typeID) ?? .severity
    name = scale.name(value)
    level = scale.level(value)
    self.sourceName = sourceName
  }
}

/// A mark: an entry (a day), a day's highest level (a week or a month; each level it has, for
/// appetite), or a week's or month's days with the symptom (six months or a year).
public struct SymptomPoint: Equatable, Sendable {
  public var start: Date
  /// An entry's end, or the end of the mark's day, week or month. Within the period, as `start`
  /// is.
  public var end: Date
  /// The mark's height or row: a level (D, W, M) or a number of days (6M, Y).
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

/// A period of a symptom: its marks, its entries (newest first) and the days it was present.
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

  /// The chart of `entries` (newest first, overlapping `interval`), as `symptomChart` makes it.
  public init(
    typeID: String, range: ChartRange, interval: DateInterval, entries: [SymptomEntry],
    calendar: Calendar
  ) {
    let scale = SymptomScale(typeID: typeID) ?? .severity
    let present = entries.reversed().filter { $0.level != nil }
    func span(_ unit: Calendar.Component, _ date: Date) -> DateInterval {
      calendar.dateInterval(of: unit, for: date) ?? DateInterval(start: date, duration: 0)
    }
    // Each day an entry covers in the period: the one it starts on (or the period's first), and
    // each after it starts before the entry ends.
    var byDay: [Date: [SymptomEntry]] = [:]
    for entry in present {
      let end = min(entry.end, interval.end)
      var day = span(.day, max(entry.start, interval.start)).start
      repeat {
        byDay[day, default: []].append(entry)
        guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
          break
        }
        day = next
      } while day < end
    }
    let points: [SymptomPoint]
    switch range {
    case .day:
      points = present.map { entry in
        let start = max(entry.start, interval.start)
        return SymptomPoint(
          start: start, end: max(min(entry.end, interval.end), start), value: entry.level ?? 0,
          entries: [entry])
      }
    case .week, .month:
      points = byDay.sorted { $0.key < $1.key }.flatMap { day, entries in
        let end = span(.day, day).end
        let levels = entries.compactMap(\.level)
        guard !scale.isOrdered else {
          return [SymptomPoint(start: day, end: end, value: levels.max() ?? 0, entries: entries)]
        }
        // Each level the day has, so none hides another.
        return Set(levels).sorted().map { level in
          SymptomPoint(
            start: day, end: end, value: level, entries: entries.filter { $0.level == level })
        }
      }
    case .sixMonths, .year:
      var buckets: [Date: (days: Int, entries: [String: SymptomEntry])] = [:]
      for (day, entries) in byDay {
        let bucket = span(range.barUnit, day).start
        buckets[bucket, default: (0, [:])].days += 1
        for entry in entries { buckets[bucket, default: (0, [:])].entries[entry.id] = entry }
      }
      points = buckets.sorted { $0.key < $1.key }.map { bucket, value in
        SymptomPoint(
          start: bucket, end: span(range.barUnit, bucket).end, value: value.days,
          entries: value.entries.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) })
      }
    }
    self.init(
      range: range, interval: interval, scale: scale, points: points, entries: entries,
      days: byDay.count)
  }
}
