public import Foundation
public import SQLiteData

/// HealthKit's sleep values (`HKCategoryValueSleepAnalysis`).
public enum SleepStage: Int, CaseIterable, Comparable, Sendable {
  case inBed = 0
  case asleep = 1
  case awake = 2
  case core = 3
  case deep = 4
  case rem = 5

  /// Time asleep: every stage but in bed and awake.
  public var isAsleep: Bool { self != .inBed && self != .awake }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
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

  public init(day: Date, segments: [SleepSegment], inBed: TimeInterval) {
    self.day = day
    self.segments = segments
    self.inBed = inBed
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
  static let sleepType = "HKCategoryTypeIdentifierSleepAnalysis"

  /// How far before midnight a night can start: sleep from 6 PM counts toward the next day, as
  /// in Health, so a night that starts at 23:00 is the next day's and an afternoon nap is its
  /// own day's.
  static let nightStartOffset: TimeInterval = 6 * 3600

  /// The `count` nights ending with `lastDay`'s, oldest first, leaving out nights without
  /// sleep. Each night uses one source, the one that recorded the most time asleep that night
  /// (usually the Watch), so overlapping sources (an iPhone's estimate, a Watch's stages) don't
  /// add up. In-bed time comes from every source.
  public static func sleepNights(
    endingOn lastDay: Date, count: Int, calendar: Calendar, _ db: Database
  ) throws -> [SleepNight] {
    let last = calendar.startOfDay(for: lastDay)
    guard let first = calendar.date(byAdding: .day, value: 1 - count, to: last),
      let end = calendar.date(byAdding: .day, value: 1, to: last)
    else { return [] }
    let lower = first.addingTimeInterval(-nightStartOffset).unixMilliseconds
    let upper = end.addingTimeInterval(-nightStartOffset).unixMilliseconds
    let samples =
      try HealthSample
      .where {
        $0.type.eq(sleepType) && $0.startDate >= lower && $0.startDate < upper
          && $0.categoryValue.isNot(nil)
      }
      .order(by: \.startDate)
      .select { ($0.startDate, $0.endDate, $0.categoryValue, $0.sourceBundleID) }
      .fetchAll(db)
    let byNight = Dictionary(grouping: samples) { start, _, _, _ in
      calendar.startOfDay(for: Date(unixMilliseconds: start).addingTimeInterval(nightStartOffset))
    }
    return byNight.compactMap { day, samples -> SleepNight? in
      let records = samples.compactMap { start, end, value, source in
        value.flatMap(SleepStage.init(rawValue:)).map {
          (
            SleepSegment(
              stage: $0, start: Date(unixMilliseconds: start), end: Date(unixMilliseconds: end)),
            source
          )
        }
      }
      var asleepBySource: [String: TimeInterval] = [:]
      for (segment, source) in records where segment.stage.isAsleep {
        asleepBySource[source, default: 0] += segment.duration
      }
      guard
        let source = asleepBySource.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
      else { return nil }
      let segments = records.filter { $0.1 == source && $0.0.stage != .inBed }.map(\.0)
      let inBed = union(records.filter { $0.0.stage == .inBed }.map(\.0))
      let span =
        (segments.map(\.end).max() ?? day).timeIntervalSince(segments.map(\.start).min() ?? day)
      return SleepNight(day: day, segments: segments, inBed: inBed > 0 ? inBed : span)
    }
    .sorted { $0.day < $1.day }
  }

  /// The total time `segments` cover, counting overlaps once.
  private static func union(_ segments: [SleepSegment]) -> TimeInterval {
    var total: TimeInterval = 0
    var current: (start: Date, end: Date)?
    for segment in segments.sorted(by: { $0.start < $1.start }) {
      if let open = current, segment.start <= open.end {
        current = (open.start, max(open.end, segment.end))
      } else {
        if let open = current { total += open.end.timeIntervalSince(open.start) }
        current = (segment.start, segment.end)
      }
    }
    if let open = current { total += open.end.timeIntervalSince(open.start) }
    return total
  }
}
