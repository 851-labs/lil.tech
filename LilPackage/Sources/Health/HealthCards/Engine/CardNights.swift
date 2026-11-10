public import Foundation

// Nights from sleep records (docs/decisions/cards.md, Event windows › Nights): Sleep's nights
// (851-3098), which its page, its highlights and cards' sleep windows all group here, so the Mac
// and the iPhone name the same nights. A night follows the zone its records were recorded in
// (851-4174, cards.md › Recorded time zones), as Apple Health draws it. The server's
// `CardNights.ts` ports this file rule for rule.

/// One sleep analysis record (`HKCategoryTypeIdentifierSleepAnalysis`), as every engine reads it.
public struct CardSleepRecord: Hashable, Sendable {
  /// Unix milliseconds.
  public var start: Int
  public var end: Int
  /// `HKCategoryValueSleepAnalysis`' raw value: In Bed 0, Asleep 1, Awake 2, Core 3, Deep 4,
  /// REM 5. Other values aren't sleep the engine knows, and are left out.
  public var value: Int
  /// The source's bundle ID: a night uses one source.
  public var source: String
  /// The zone it was recorded in (`HKTimeZone`), when that's a name the tools' `timeZone` takes
  /// (`CardTimeZone.named(_:)`), else `nil`. Its night follows it (`CardNights.nights`).
  public private(set) var timeZone: TimeZone?
  /// `timeZone`'s name as the record gave it, which `TimeZone` doesn't always keep (`UTC` is
  /// `GMT` there): what ties between zones compare, as on the server, and what the `sleep` tools
  /// say (851-4177). `nil` without a zone. Both are set by `init`, so they always agree.
  public private(set) var timeZoneName: String?

  /// `timeZoneName` defaults to `timeZone`'s identifier.
  public init(
    start: Int, end: Int, value: Int, source: String, timeZone: TimeZone? = nil,
    timeZoneName: String? = nil
  ) {
    self.start = start
    self.end = end
    self.value = value
    self.source = source
    self.timeZone = timeZone
    self.timeZoneName = timeZone.map { timeZoneName ?? $0.identifier }
  }

  public static let inBed = 0
  public static let awake = 2

  /// Whether it's a value the engine knows (In Bed, Asleep, Awake, Core, Deep or REM).
  public var isKnown: Bool { (0...5).contains(value) }
  /// Whether it's time asleep: Asleep, Core, Deep or REM.
  public var isAsleep: Bool { isKnown && value != Self.inBed && value != Self.awake }

  var duration: Int { end - start }
}

/// A night's sleep, named by the day it ends on, as Health does.
public struct CardNight: Hashable, Sendable {
  /// The start of the day the night belongs to, in the engine's calendar: the calendar's day of
  /// the date the night has on its own clock.
  public var day: Date
  /// The zone it was recorded in (`CardNights.nights`), or `nil` for the calendar's. Its date,
  /// bedtime and clock are that zone's (`CardNights.clock(day:timeZone:calendar:)`).
  public private(set) var timeZone: TimeZone?
  /// Its zone's name, as its records gave it (`CardSleepRecord.timeZoneName`), `nil` without one.
  public private(set) var timeZoneName: String?
  /// The chosen source's records in its main session, by start: its stages, awake included, but
  /// not In Bed.
  public var records: [CardSleepRecord]
  /// Time in bed, in milliseconds: every source's In Bed records that overlap the night, counted
  /// once, wherever they start; without any, the night's span.
  public var inBed: Int

  /// `records` are sorted by start (ties keep their order), as F, W and the stretches need.
  /// `timeZoneName` defaults to `timeZone`'s identifier.
  public init(
    day: Date, records: [CardSleepRecord], inBed: Int, timeZone: TimeZone? = nil,
    timeZoneName: String? = nil
  ) {
    self.day = day
    self.records = records.sorted { $0.start < $1.start }
    self.inBed = inBed
    self.timeZone = timeZone
    self.timeZoneName = timeZone.map { timeZoneName ?? $0.identifier }
  }

  /// `F`: when sleep started, the start of its first record asleep (not getting into bed, or lying
  /// awake before).
  public var fallingAsleep: Int? { records.first(where: \.isAsleep)?.start }

  /// `W`: when sleep ended, the latest end among its records asleep (not lying awake after, or
  /// getting up).
  public var waking: Int? { records.lazy.filter(\.isAsleep).map(\.end).max() }

  /// Its stretches asleep, by start: its records asleep, merged where they touch or overlap, so
  /// lying awake in the night isn't part of them.
  public var asleepStretches: [CardStretch] {
    var stretches: [CardStretch] = []
    for record in records where record.isAsleep && record.start < record.end {
      if let last = stretches.last, record.start <= last.end {
        stretches[stretches.count - 1].end = max(last.end, record.end)
      } else {
        stretches.append(CardStretch(start: record.start, end: record.end))
      }
    }
    return stretches
  }

  /// Its bedtime on its own clock (its zone's), in hours from its day's midnight there
  /// (`CardNights.clockHours`, placed from its first record), if it's a night's sleep rather than
  /// a day's: sleep that starts before noon (`CardNights.latestBedtime`). `nil` for a day's sleep.
  public func nightBedtime(calendar: Calendar) -> Double? {
    guard let fallingAsleep, let first = records.map(\.start).min() else { return nil }
    let clock = CardNights.clock(day: day, timeZone: timeZone, calendar: calendar)
    return CardNights.nightBedtime(
      fallingAsleep: Date(unixMilliseconds: fallingAsleep),
      firstStart: Date(unixMilliseconds: first),
      day: clock.day, calendar: clock.calendar)
  }
}

public enum CardNights {
  /// How far before midnight a night can start: sleep from 6 PM counts toward the next day, as in
  /// Health, so a night that starts at 23:00 is the next day's, and an afternoon nap is its own
  /// day's.
  public static let startOffset: TimeInterval = 6 * 3600

  /// A gap this long between stretches of sleep starts a new session: a nap after the night.
  public static let sessionGap: TimeInterval = 3 * 3600

  /// The latest a night's sleep can start, in hours from its day's midnight, to be a night's:
  /// noon. Later is a day's sleep, a nap on a day whose night wasn't recorded, which Sleep's
  /// highlights and cards leave out.
  public static let latestBedtime: Double = 12

  /// How far a day's midnight in another zone can be from the calendar's: 26 hours, from
  /// UTC−12 to UTC+14. A night recorded in another zone starts up to that far outside the
  /// calendar's days (851-4174).
  public static let zoneReach: TimeInterval = 26 * 3600

  /// The records the nights of `days` (local midnights, the first day's up to the day after the
  /// last's) are made of, in any zone: those that end after the first night can start and start
  /// before the day after the last's can, `zoneReach` wider on each side, in Unix milliseconds.
  /// In Bed records may start before it. Cards' sleep windows (`CardWindowFetch.sleep`), Sleep's
  /// page and the `sleep` tools all fetch it, and `nights` keeps the nights of `days`.
  public static func recordRange(days: Range<Date>) -> Range<Int> {
    days.lowerBound.addingTimeInterval(-startOffset - zoneReach)
      .unixMilliseconds..<days.upperBound.addingTimeInterval(-startOffset + zoneReach)
      .unixMilliseconds
  }

  /// The nights of `days`, oldest first, leaving out days without sleep, from `records` (by start,
  /// as `recordRange(days:)` gives them). Nights' and days' sleep both: Sleep's page shows a
  /// day's, which `CardNight.nightBedtime(calendar:)` tells apart.
  /// - **The zone** (851-4174): each source's records (but In Bed) are split into runs where
  ///   sleep stops for `sessionGap` or more, in absolute time, as sessions are. A run's zone is
  ///   that of the last-ending of its records that have one (ties to the name that sorts first),
  ///   else the calendar's (`nil`). A night's main session is part of one run, so the night has
  ///   its run's zone. Records in one zone, or in none, give the nights they always did.
  /// - **The day:** a record belongs to the day `startOffset` after its start on its run's
  ///   zone's clock: the calendar's day of that date. Only the nights of `days` are kept.
  /// - **Source:** each night uses one source, the one with the most time asleep that day
  ///   (usually the Watch), ties to the bundle ID that sorts first, so overlapping sources (an
  ///   iPhone's estimate, a Watch's stages) don't add up.
  /// - **The night:** that source's session with the most sleep, its records split wherever the
  ///   next starts `sessionGap` or more after the latest end so far. Naps on the same day aren't
  ///   part of it.
  /// - **In bed:** every source's In Bed records that overlap the night, counted once, wherever
  ///   they start. Without any, the night's span.
  public static func nights(
    _ records: [CardSleepRecord], days: Range<Date>, calendar: Calendar
  ) -> [CardNight] {
    let records = records.filter(\.isKnown)
    let inBedRecords = records.filter { $0.value == CardSleepRecord.inBed }
    var byDay: [Date: [Placed]] = [:]
    for (placed, day) in place(records.filter { $0.value != CardSleepRecord.inBed }, calendar)
    where days.contains(day) {
      byDay[day, default: []].append(placed)
    }
    return byDay.compactMap { day, placed -> CardNight? in
      var asleepBySource: [String: Int] = [:]
      for record in placed.map(\.record) where record.isAsleep {
        asleepBySource[record.source, default: 0] += record.duration
      }
      guard
        let source = asleepBySource.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
      else { return nil }
      let session = mainSession(placed.filter { $0.record.source == source })
      let records = session.map(\.record)
      guard let start = records.map(\.start).min(), let end = records.map(\.end).max()
      else { return nil }
      let inBed = union(inBedRecords.filter { $0.start < end && $0.end > start })
      return CardNight(
        day: day, records: records, inBed: inBed > 0 ? inBed : end - start,
        timeZone: session[0].timeZone, timeZoneName: session[0].timeZoneName)
    }
    .sorted { $0.day < $1.day }
  }

  /// `records` (none In Bed) with their runs' zones (`runs`) and their days on those zones'
  /// clocks, as the calendar's days. Zones are looked up once a run, not once a record.
  private static func place(
    _ records: [CardSleepRecord], _ calendar: Calendar
  ) -> [(placed: Placed, day: Date)] {
    let offset = Int(startOffset * 1000)
    var days = NightDays(calendar: calendar)
    var placed: [(placed: Placed, day: Date)?] = Array(repeating: nil, count: records.count)
    for run in runs(records) {
      let clock = days.clock(run.timeZone)
      for index in run.indices {
        let record = records[index]
        placed[index] = (
          Placed(record: record, timeZone: run.timeZone, timeZoneName: run.timeZoneName),
          days.day(ofMilliseconds: record.start + offset, clock: clock)
        )
      }
    }
    return placed.map { $0! }
  }

  /// A record and its run's zone (`runs`).
  private struct Placed {
    var record: CardSleepRecord
    var timeZone: TimeZone?
    var timeZoneName: String?
  }

  /// `records`' runs, by their indices: each source's records split where sleep stops for
  /// `sessionGap` or more (as `mainSession` splits them), each run taking the zone of the
  /// last-ending of its records that have one, ties to the name that sorts first, so the
  /// records' order never matters; `nil` for a run without any, the calendar's. When no record
  /// has a zone (as before 851-4174, or from apps that don't say), one run of them all.
  static func runs(_ records: [CardSleepRecord]) -> [Run] {
    guard records.contains(where: { $0.timeZone != nil }) else {
      return [Run(indices: Array(records.indices))]
    }
    let gap = Int(sessionGap * 1000)
    var runs: [Run] = []
    for indices in Dictionary(grouping: records.indices, by: { records[$0].source }).values {
      var run: [Int] = []
      func close() {
        // The record whose zone the run takes.
        var zoned: CardSleepRecord?
        for index in run {
          let record = records[index]
          guard let name = record.timeZoneName else { continue }
          if let last = zoned,
            record.end < last.end || (record.end == last.end && name >= last.timeZoneName!)
          {
            continue
          }
          zoned = record
        }
        runs.append(
          Run(indices: run, timeZone: zoned?.timeZone, timeZoneName: zoned?.timeZoneName))
        run = []
      }
      var lastEnd: Int?
      for index in indices.sorted(by: { records[$0].start < records[$1].start }) {
        let record = records[index]
        if let lastEnd, record.start - lastEnd >= gap { close() }
        run.append(index)
        lastEnd = max(lastEnd ?? record.end, record.end)
      }
      close()
    }
    return runs
  }

  /// A run of a source's records (`runs`): their indices, and the zone they take, by its name.
  struct Run {
    var indices: [Int]
    var timeZone: TimeZone?
    var timeZoneName: String?
  }

  /// Each of `records`' runs' zones (`runs`), in their order.
  static func runZones(_ records: [CardSleepRecord]) -> [TimeZone?] {
    var zones = [TimeZone?](repeating: nil, count: records.count)
    for run in runs(records) {
      for index in run.indices { zones[index] = run.timeZone }
    }
    return zones
  }

  /// The session with the most sleep among `records`, splitting where sleep stops for
  /// `sessionGap` or more.
  private static func mainSession(_ records: [Placed]) -> [Placed] {
    let gap = Int(sessionGap * 1000)
    var sessions: [[Placed]] = []
    var lastEnd: Int?
    for placed in records.sorted(by: { $0.record.start < $1.record.start }) {
      let record = placed.record
      if let lastEnd, record.start - lastEnd < gap, !sessions.isEmpty {
        sessions[sessions.count - 1].append(placed)
      } else {
        sessions.append([placed])
      }
      lastEnd = max(lastEnd ?? record.end, record.end)
    }
    let asleep = { (session: [Placed]) in
      session.lazy.map(\.record).filter(\.isAsleep).reduce(0) { $0 + $1.duration }
    }
    return sessions.max { asleep($0) < asleep($1) } ?? []
  }

  /// The total time `records` cover, counting overlaps once.
  private static func union(_ records: [CardSleepRecord]) -> Int {
    var total = 0
    var current: (start: Int, end: Int)?
    for record in records.sorted(by: { $0.start < $1.start }) {
      if let open = current, record.start <= open.end {
        current = (open.start, max(open.end, record.end))
      } else {
        if let open = current { total += open.end - open.start }
        current = (record.start, record.end)
      }
    }
    if let open = current { total += open.end - open.start }
    return total
  }

  /// A night's clock: the calendar in its zone (`CardNight.timeZone`), and the midnight there
  /// that starts its day's date. The calendar and `day` themselves for a night in none, or in the
  /// calendar's.
  public static func clock(
    day: Date, timeZone: TimeZone?, calendar: Calendar
  ) -> (calendar: Calendar, day: Date) {
    guard let zoned = zoned(calendar, timeZone) else { return (calendar, day) }
    return (zoned, sameDate(day, from: calendar, in: zoned))
  }

  /// `calendar` in `timeZone`, or `nil` for none or the calendar's own: the one comparison that
  /// decides whether a night is on another clock, for placing its records and reading its clock.
  static func zoned(_ calendar: Calendar, _ timeZone: TimeZone?) -> Calendar? {
    guard let timeZone, timeZone != calendar.timeZone else { return nil }
    var zoned = calendar
    zoned.timeZone = timeZone
    return zoned
  }

  /// The start of the day in `target` with the date `day` has in `source`. Through noon, so a
  /// zone whose clocks skip midnight still has the day.
  static func sameDate(_ day: Date, from source: Calendar, in target: Calendar) -> Date {
    var date = source.dateComponents([.era, .year, .month, .day], from: day)
    date.hour = 12
    return target.date(from: date).map(target.startOfDay(for:)) ?? day
  }

  /// Where `date` goes in the night that started at `start`, in hours from the start of `day`,
  /// the night's, on the local clock as it read when the night started: 11 PM the evening before
  /// is -1, 7:30 AM is 7.5. Each night is placed at the clock time it started, so a daylight
  /// saving change doesn't move the nights after it, and runs its true length from there.
  public static func clockHours(
    _ date: Date, from day: Date, start: Date, calendar: Calendar
  ) -> Double {
    let zone = calendar.timeZone
    let shift = zone.secondsFromGMT(for: start) - zone.secondsFromGMT(for: day)
    return (date.timeIntervalSince(day) + Double(shift)) / 3600
  }

  /// A night's bedtime on the clock (`clockHours`, placed from its first record's start), if it's
  /// before `latestBedtime`: a night's sleep. `nil` for a day's.
  public static func nightBedtime(
    fallingAsleep: Date, firstStart: Date, day: Date, calendar: Calendar
  ) -> Double? {
    let hours = clockHours(fallingAsleep, from: day, start: firstStart, calendar: calendar)
    return hours < latestBedtime ? hours : nil
  }
}

/// Days of sleep records' starts on their nights' clocks (`CardNights.nights`), as the
/// calendar's days: per day, not per record, as the cards' time-zone math is (851-2906).
private struct NightDays {
  let calendar: Calendar
  /// The calendar's bucketer, then one for each other zone, with its days' starts mapped to the
  /// calendar's days.
  var clocks: [(bucketer: CardBucketer, days: [Date: Date])]
  var indices: [TimeZone: Int] = [:]

  init(calendar: Calendar) {
    self.calendar = calendar
    clocks = [(CardBucketer(CardGrain.day, calendar: calendar), [:])]
  }

  /// Which clock places records in `timeZone`: 0, the calendar's, for none or the calendar's.
  mutating func clock(_ timeZone: TimeZone?) -> Int {
    guard let timeZone, let zoned = CardNights.zoned(calendar, timeZone) else { return 0 }
    if let index = indices[timeZone] { return index }
    clocks.append((CardBucketer(CardGrain.day, calendar: zoned), [:]))
    indices[timeZone] = clocks.count - 1
    return clocks.count - 1
  }

  mutating func day(ofMilliseconds milliseconds: Int, clock: Int) -> Date {
    let start = clocks[clock].bucketer.start(ofMilliseconds: milliseconds)
    guard clock != 0 else { return start }
    if let day = clocks[clock].days[start] { return day }
    let day = CardNights.sameDate(start, from: clocks[clock].bucketer.calendar, in: calendar)
    clocks[clock].days[start] = day
    return day
  }
}
