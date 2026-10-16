public import Foundation
public import HealthKit
import IssueReporting

/// A heartbeat series' contents, read out of `HKHeartbeatSeriesSample` and its query
/// (`init(_:store:)`), so the encoding can be tested without HealthKit.
public struct HeartbeatSeriesRecord: Equatable, Sendable {
  public var id: UUID
  /// Each beat's time, in seconds since the series' start, in order.
  public var beats: [TimeInterval]
  /// The indices of the beats preceded by a gap: beats HealthKit couldn't measure came before.
  public var gaps: [Int]
  /// Times, source, device and metadata (`HealthEncoder.provenance(of:)`).
  public var provenance: [String: JSONValue]

  public init(
    id: UUID, beats: [TimeInterval], gaps: [Int], provenance: [String: JSONValue]
  ) {
    self.id = id
    self.beats = beats
    self.gaps = gaps
    self.provenance = provenance
  }
}

extension HeartbeatSeriesRecord {
  /// Reads a heartbeat series out of HealthKit, with its beats. Throws `HealthReader.Locked` if
  /// the device locks meanwhile, and `HealthReader.SeriesUnavailable` if the query fails. A
  /// count that doesn't match is reported, and the beats are kept as read.
  public init(_ series: HKHeartbeatSeriesSample, store: HKHealthStore) async throws {
    var beats: [TimeInterval] = []
    var gaps: [Int] = []
    beats.reserveCapacity(series.count)
    do {
      for try await beat in HKHeartbeatSeriesQueryDescriptor(series).results(for: store) {
        if beat.precededByGap { gaps.append(beats.count) }
        beats.append(beat.timeIntervalSinceStart)
      }
    } catch {
      let mapped = HealthReader.Locked.mapped(error)
      if mapped is HealthReader.Locked || mapped is CancellationError { throw mapped }
      throw HealthReader.SeriesUnavailable(expected: series.count, read: beats.count)
    }
    try Task.checkCancellation()
    if beats.count != series.count {
      reportIssue(HealthReader.SeriesCountMismatch(expected: series.count, read: beats.count))
    }
    self.init(
      id: series.uuid, beats: beats, gaps: gaps, provenance: HealthEncoder.provenance(of: series))
  }
}

extension HealthEncoder {
  public static let heartbeatSeriesEntity = "health_heartbeat_series"

  /// A heartbeat series, its beats and gaps as JSON (`HealthHeartbeatSeries` on the server).
  /// Beat times are rounded to 0.1 ms, which keeps a third-party app's all-day series (~100,000
  /// beats) within a batch line's 1 MB.
  public static func heartbeatSeries(_ series: HeartbeatSeriesRecord) -> HealthMutation {
    var row = series.provenance
    row["beats"] = .array(series.beats.map { .number(($0 * 10_000).rounded() / 10_000) })
    row["gaps"] = .array(series.gaps.map { .number(Double($0)) })
    return .upsert(heartbeatSeriesEntity, id: id(series.id), row: row)
  }
}
