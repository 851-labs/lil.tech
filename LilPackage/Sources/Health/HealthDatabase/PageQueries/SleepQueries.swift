public import Foundation
import HealthCards
public import SQLiteData

/// HealthKit's sleep values (`HKCategoryValueSleepAnalysis`).
public enum SleepStage: Int, CaseIterable, Sendable {
  case inBed = 0
  case asleep = 1
  case awake = 2
  case core = 3
  case deep = 4
  case rem = 5

  /// Time asleep: every stage but in bed and awake.
  public var isAsleep: Bool { self != .inBed && self != .awake }
}

/// One stretch of a night in one stage.
public struct SleepSegment: Equatable, Sendable {
  public var stage: SleepStage
  public var start: Date
  public var end: Date

  public init(stage: SleepStage, start: Date, end: Date) {
    self.stage = stage
    self.start = start
    self.end = end
  }

  public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A night's sleep, named by the day it ends on, as Health does.
public struct SleepNight: Equatable, Identifiable, Sendable {
  public var id: Date { day }
  /// The start of the day the night belongs to.
  public var day: Date
  /// The chosen source's stages, by start (in bed isn't one of them).
  public var segments: [SleepSegment]
  /// Time in bed: from in-bed records, or, without any, from the first segment to the last.
  public var inBed: TimeInterval
  /// The zone it was recorded in (`CardNight.timeZone`, 851-4174), or `nil` for the calendar's:
  /// its date and clock are that zone's.
  public var timeZone: TimeZone?

  public init(
    day: Date, segments: [SleepSegment], inBed: TimeInterval, timeZone: TimeZone? = nil
  ) {
    self.day = day
    self.segments = segments
    self.inBed = inBed
    self.timeZone = timeZone
  }

  public var asleep: TimeInterval {
    segments.filter(\.stage.isAsleep).reduce(0) { $0 + $1.duration }
  }

  /// Time in each stage.
  public var durations: [SleepStage: TimeInterval] {
    segments.reduce(into: [:]) { $0[$1.stage, default: 0] += $1.duration }
  }

  /// Whether the source recorded stages (Core, Deep, REM), not just asleep.
  public var hasStages: Bool { segments.contains { [.core, .deep, .rem].contains($0.stage) } }
}

extension HealthDatabase {
  public static let sleepType = "HKCategoryTypeIdentifierSleepAnalysis"

  /// Whether any sleep was ever recorded, which Sleep's page asks of a period without nights, to
  /// tell a period without sleep from an account without any (851-3102).
  public static func hasSleep(_ db: Database) throws -> Bool {
    try HealthSample
      .where { $0.type.eq(sleepType) }
      .select { $0.id }
      .limit(1)
      .fetchOne(db) != nil
  }

  /// How far before midnight a night can start (`CardNights.startOffset`): sleep from 6 PM
  /// counts toward the next day.
  static let nightStartOffset: TimeInterval = CardNights.startOffset

  /// The `count` nights ending with `lastDay`'s, oldest first, leaving out nights without
  /// sleep.
  /// - **Source:** each night uses one source, the one that recorded the most time asleep that
  ///   day (usually the Watch), so overlapping sources (an iPhone's estimate, a Watch's stages)
  ///   don't add up.
  /// - **The night:** that source's longest session, its stretches of sleep with gaps under 3
  ///   hours. Naps on the same day aren't part of it.
  /// - **In bed:** every source's in-bed records that overlap the night, counted once, wherever
  ///   they start. Without any, the night's span.
  public static func sleepNights(
    endingOn lastDay: Date, count: Int, calendar: Calendar, _ db: Database
  ) throws -> [SleepNight] {
    let last = calendar.startOfDay(for: lastDay)
    guard let first = calendar.date(byAdding: .day, value: 1 - count, to: last),
      let end = calendar.date(byAdding: .day, value: 1, to: last)
    else { return [] }
    let days = first..<end
    // Grouped by cards' core (851-3196), so cards' nights are these, on the Mac and the iPhone.
    return CardNights.nights(
      try sleepRecords(in: CardNights.recordRange(days: days), db), days: days, calendar: calendar
    )
    .map { night in
      SleepNight(
        day: night.day,
        segments: night.records.compactMap { record in
          SleepStage(rawValue: record.value).map {
            SleepSegment(
              stage: $0, start: Date(unixMilliseconds: record.start),
              end: Date(unixMilliseconds: record.end))
          }
        },
        inBed: Double(night.inBed) / 1000, timeZone: night.timeZone)
    }
  }

  /// Sleep analysis records that end after `range` starts and start before it ends (Unix
  /// milliseconds), by start: In Bed records can start well before a night. Each with the zone it
  /// was recorded in (`HKTimeZone`, 851-4174), which its night follows, when that's a name the
  /// tools take (`CardTimeZone.named`). Metadata that isn't JSON, or a zone that isn't a string,
  /// loses only the zone. `startingFrom` leaves out records starting before it, which bounds the
  /// index's range from below too: only In Bed records start long before a night.
  static func sleepRecords(
    in range: Range<Int>, startingFrom earliest: Int = .min, _ db: Database
  ) throws -> [CardSleepRecord] {
    let (lower, upper) = (range.lowerBound, range.upperBound)
    var zones: [String: TimeZone?] = [:]
    return
      try HealthSample
      .where {
        $0.type.eq(sleepType) && $0.startDate >= earliest && $0.startDate < upper
          && $0.endDate > lower && $0.categoryValue.isNot(nil)
      }
      .order(by: \.startDate)
      .select {
        (
          $0.startDate, $0.endDate, $0.categoryValue, $0.sourceBundleID,
          #sql(
            """
            CASE WHEN json_valid(\($0.metadata)) AND json_type(\($0.metadata), '$.HKTimeZone') = 'text'
            THEN json_extract(\($0.metadata), '$.HKTimeZone') END
            """, as: String?.self)
        )
      }
      .fetchAll(db)
      .compactMap { start, end, value, source, zone in
        // A few names among thousands of records: each checked once.
        let timeZone = zone.flatMap { name in
          zones[name]
            ?? {
              let zone = CardTimeZone.named(name)
              zones[name] = zone
              return zone
            }()
        }
        return value.map {
          CardSleepRecord(start: start, end: end, value: $0, source: source, timeZone: timeZone)
        }
      }
  }
}
