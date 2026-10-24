public import Foundation

// Nights from sleep records (docs/decisions/cards.md, Event windows › Nights): Sleep's nights
// (851-3098), which its page, its highlights and cards' sleep windows all group here, so the Mac
// and the iPhone name the same nights.

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

  public init(start: Int, end: Int, value: Int, source: String) {
    self.start = start
    self.end = end
    self.value = value
    self.source = source
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
  /// The start of the day the night belongs to.
  public var day: Date
  /// The chosen source's records in its main session, by start: its stages, awake included, but
  /// not In Bed.
  public var records: [CardSleepRecord]
  /// Time in bed, in milliseconds: every source's In Bed records that overlap the night, counted
  /// once, wherever they start; without any, the night's span.
  public var inBed: Int

  /// `records` are sorted by start (ties keep their order), as F, W and the stretches need.
  public init(day: Date, records: [CardSleepRecord], inBed: Int) {
    self.day = day
    self.records = records.sorted { $0.start < $1.start }
    self.inBed = inBed
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

  /// Its bedtime on the clock, in hours from its day's midnight (`CardNights.clockHours`, placed
  /// from its first record), if it's a night's sleep rather than a day's: sleep that starts before
  /// noon (`CardNights.latestBedtime`). `nil` for a day's sleep.
  public func nightBedtime(calendar: Calendar) -> Double? {
    guard let fallingAsleep, let first = records.map(\.start).min() else { return nil }
    return CardNights.nightBedtime(
      fallingAsleep: Date(unixMilliseconds: fallingAsleep),
      firstStart: Date(unixMilliseconds: first),
      day: day, calendar: calendar)
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

  /// The records the nights of `days` (local midnights, the first day's up to the day after the
  /// last's) are made of: those that end after the first night can start and start before the
  /// day after the last's can, in Unix milliseconds. In Bed records may start before it.
  public static func recordRange(days: Range<Date>) -> Range<Int> {
    days.lowerBound.addingTimeInterval(-startOffset)
      .unixMilliseconds..<days.upperBound.addingTimeInterval(-startOffset).unixMilliseconds
  }

  /// The nights of `days`, oldest first, leaving out days without sleep, from `records` (by start,
  /// as `recordRange(days:)` gives them). Nights' and days' sleep both: Sleep's page shows a
  /// day's, which `CardNight.nightBedtime(calendar:)` tells apart.
  /// - **The day:** a record belongs to the day `startOffset` after its start, when it starts in
  ///   the range.
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
    let range = recordRange(days: days)
    let offset = Int(startOffset * 1000)
    let records = records.filter(\.isKnown)
    let inBedRecords = records.filter { $0.value == CardSleepRecord.inBed }
    var bucketer = CardBucketer(CardGrain.day, calendar: calendar)
    var byDay: [Date: [CardSleepRecord]] = [:]
    for record in records
    where record.value != CardSleepRecord.inBed && range.contains(record.start) {
      byDay[bucketer.start(ofMilliseconds: record.start + offset), default: []].append(record)
    }
    return byDay.compactMap { day, records -> CardNight? in
      var asleepBySource: [String: Int] = [:]
      for record in records where record.isAsleep {
        asleepBySource[record.source, default: 0] += record.duration
      }
      guard
        let source = asleepBySource.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
      else { return nil }
      let session = mainSession(records.filter { $0.source == source })
      guard let start = session.map(\.start).min(), let end = session.map(\.end).max()
      else { return nil }
      let inBed = union(inBedRecords.filter { $0.start < end && $0.end > start })
      return CardNight(day: day, records: session, inBed: inBed > 0 ? inBed : end - start)
    }
    .sorted { $0.day < $1.day }
  }

  /// The session with the most sleep among `records`, splitting where sleep stops for
  /// `sessionGap` or more.
  private static func mainSession(_ records: [CardSleepRecord]) -> [CardSleepRecord] {
    let gap = Int(sessionGap * 1000)
    var sessions: [[CardSleepRecord]] = []
    var lastEnd: Int?
    for record in records.sorted(by: { $0.start < $1.start }) {
      if let lastEnd, record.start - lastEnd < gap, !sessions.isEmpty {
        sessions[sessions.count - 1].append(record)
      } else {
        sessions.append([record])
      }
      lastEnd = max(lastEnd ?? record.end, record.end)
    }
    let asleep = { (session: [CardSleepRecord]) in
      session.filter(\.isAsleep).reduce(0) { $0 + $1.duration }
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
