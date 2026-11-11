import Foundation
import HealthDatabase
public import SQLiteData

// The heartbeat series tools (851-4162): `heartbeat_series` lists Apple Watch's beat-to-beat
// measurements from their rows, with the average heart rate and HRV the app's Beat-to-Beat
// Measurements page works out (`HeartbeatAnalysis`), and `heartbeat_series_beats` gives one
// series' beats, a page at a time, as the privacy policy says (851-4157). Beats are JSON in the
// row, not a blob. The remote server does the same
// (`Services/api/src/health/tools/HeartbeatSeries.ts`), rule for rule.

extension HealthTools {
  /// The most heartbeat series `heartbeat_series` lists.
  public static let heartbeatSeriesLimit = 100
  /// The most beats `heartbeat_series_beats` gives a page, and how many it gives by default.
  public static let heartbeatBeatsLimit = 2_000
  public static let heartbeatBeatsDefaultLimit = 1_000

  // MARK: - heartbeat_series

  /// The series that start in the period, newest first, at most `heartbeatSeriesLimit`, with how
  /// many there are.
  public func heartbeatSeries(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthHeartbeatSeriesResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let (count, series) = try HealthDatabase.heartbeatSeries(
      in: period.interval, limit: Self.heartbeatSeriesLimit, db)
    let zones = RecordedZones()
    return HealthHeartbeatSeriesResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: count,
      series: series.map { series in
        let (times, gaps) = series.decodedBeats
        let analysis = HeartbeatAnalysis(beats: times, gaps: gaps)
        let recorded = zones.times(
          json: series.metadata, start: series.startDate, end: series.endDate)
        return HealthHeartbeatSeriesItem(
          id: series.id,
          start: time.localTime(Date(unixMilliseconds: series.startDate)),
          end: time.localTime(Date(unixMilliseconds: series.endDate)),
          recordedTimeZone: recorded.timeZone, recordedStart: recorded.start,
          recordedEnd: recorded.end,
          beatCount: analysis.beatCount, duration: Self.rounded(analysis.duration, 10_000),
          gapCount: times.indices.count(where: gaps.contains),
          intervalCount: analysis.beats.count,
          averageHeartRate: analysis.averageBeatsPerMinute.map { Self.rounded($0, 100) },
          sdnn: analysis.sdnn.map { Self.rounded($0, 100) },
          rmssd: analysis.rmssd.map { Self.rounded($0, 100) },
          source: series.sourceName)
      })
  }

  // MARK: - heartbeat_series_beats

  /// A page of a series' beats: `limit` of them from the cursor, the index of the page's first.
  public func heartbeatSeriesBeats(
    id: String, timeZone: String? = nil, cursor: String? = nil, limit: Int? = nil,
    _ db: Database
  ) throws -> HealthHeartbeatSeriesBeatsResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let limit = limit ?? Self.heartbeatBeatsDefaultLimit
    guard (1...Self.heartbeatBeatsLimit).contains(limit) else {
      throw HealthToolError("The limit must be from 1 to \(Self.heartbeatBeatsLimit).")
    }
    guard let series = try HealthHeartbeatSeries.where({ $0.id.eq(id) }).fetchOne(db) else {
      throw HealthToolError(
        "No heartbeat series with ID \(id). heartbeat_series lists them, with their IDs.")
    }
    let (times, gaps) = series.decodedBeats
    let start =
      try cursor.map { cursor in
        guard let index = Self.cursorIndex(cursor), index <= times.count else {
          throw HealthToolError("Invalid cursor: \(cursor). Pass the previous page's nextCursor.")
        }
        return index
      } ?? 0
    let end = min(start + limit, times.count)
    return HealthHeartbeatSeriesBeatsResult(
      timeZone: time.name, id: series.id,
      start: time.localTime(Date(unixMilliseconds: series.startDate)), beatCount: times.count,
      beats: (start..<end).map { index in
        let precededByGap = gaps.contains(index)
        return HealthHeartbeat(
          time: Self.rounded(times[index], 10_000),
          interval: index == 0 || precededByGap
            ? nil : Self.rounded((times[index] - times[index - 1]) * 1000, 10),
          precededByGap: precededByGap)
      },
      nextCursor: end < times.count ? String(end) : nil)
  }
}

// MARK: - Outputs

/// A heartbeat series, with the average heart rate and HRV its intervals give.
public struct HealthHeartbeatSeriesItem: Codable, Equatable, Sendable {
  public var id: String
  public var start: String
  public var end: String
  /// The zone it was recorded in (`HKTimeZone`), when it's a name the tools take, and its start
  /// and end on that zone's clock (851-4177); `nil` without one, and left out of the JSON.
  public var recordedTimeZone: String? = nil
  public var recordedStart: String? = nil
  public var recordedEnd: String? = nil
  public var beatCount: Int
  /// Seconds from its first beat to its last.
  public var duration: Double
  public var gapCount: Int
  public var intervalCount: Int
  /// Beats per minute.
  public var averageHeartRate: Double?
  /// Milliseconds.
  public var sdnn: Double?
  /// Milliseconds.
  public var rmssd: Double?
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    try container.encodeIfPresent(recordedStart, forKey: .recordedStart)
    try container.encodeIfPresent(recordedEnd, forKey: .recordedEnd)
    try container.encode(beatCount, .beatCount)
    try container.encode(duration, .duration)
    try container.encode(gapCount, .gapCount)
    try container.encode(intervalCount, .intervalCount)
    try container.encode(averageHeartRate, .averageHeartRate)
    try container.encode(sdnn, .sdnn)
    try container.encode(rmssd, .rmssd)
    try container.encode(source, .source)
  }
}

public struct HealthHeartbeatSeriesResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var series: [HealthHeartbeatSeriesItem]
}

/// A beat: seconds since its series' start, milliseconds since the beat before (`nil` for the
/// first and after a gap), and whether a gap preceded it.
public struct HealthHeartbeat: Codable, Equatable, Sendable {
  public var time: Double
  public var interval: Double?
  public var precededByGap: Bool

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(time, .time)
    try container.encode(interval, .interval)
    try container.encode(precededByGap, .precededByGap)
  }
}

public struct HealthHeartbeatSeriesBeatsResult: HealthToolOutput {
  public var timeZone: String
  public var id: String
  /// When the series starts: its beats' time 0.
  public var start: String
  public var beatCount: Int
  public var beats: [HealthHeartbeat]
  public var nextCursor: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(id, .id)
    try container.encode(start, .start)
    try container.encode(beatCount, .beatCount)
    try container.encode(beats, .beats)
    try container.encode(nextCursor, .nextCursor)
  }
}
