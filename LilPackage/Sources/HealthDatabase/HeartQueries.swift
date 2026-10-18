import Foundation
public import SQLiteData

extension HealthDatabase {
  public static let heartRateType = "HKQuantityTypeIdentifierHeartRate"
  public static let restingHeartRateType = "HKQuantityTypeIdentifierRestingHeartRate"
  public static let walkingHeartRateType = "HKQuantityTypeIdentifierWalkingHeartRateAverage"
  /// The HRV types, whose detail links to the beat-to-beat measurements behind them.
  public static let heartRateVariabilityTypes: Set<String> = [
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD",
  ]

  /// Heartbeat series (Apple Watch's beat-to-beat measurements), newest first, at most `limit`.
  public static func heartbeatSeries(limit: Int, _ db: Database) throws -> [HealthHeartbeatSeries] {
    try HealthHeartbeatSeries
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }
}

/// What a heartbeat series says: each beat's instantaneous heart rate, and its average and
/// variability, from the time between beats. A beat after a gap starts afresh: the time back to
/// the one before isn't an interval between two beats.
public struct HeartbeatAnalysis: Equatable, Sendable {
  /// An interval between two beats: when it ended (seconds into the series) and its heart rate.
  public struct Beat: Equatable, Sendable {
    public var time: Double
    public var beatsPerMinute: Double
    /// Which unbroken run of beats it's in, counting gaps from 0, so a chart doesn't join
    /// intervals across a gap.
    public var run: Int
  }

  public var beats: [Beat]
  public var beatCount: Int
  /// Seconds from the first beat to the last.
  public var duration: Double
  public var averageBeatsPerMinute: Double?
  /// The standard deviation of the intervals, in ms (what Apple Watch's HRV is).
  public var sdnn: Double?
  /// The root mean square of successive differences between intervals, in ms.
  public var rmssd: Double?

  public init(beats times: [Double], gaps: Set<Int>) {
    var intervals: [Double] = []
    var beats: [Beat] = []
    var successive: [Double] = []
    var previous: Double?
    var run = 0
    for index in times.indices.dropFirst() {
      if gaps.contains(index) {
        previous = nil
        run += 1
        continue
      }
      let interval = times[index] - times[index - 1]
      guard interval > 0 else { continue }
      intervals.append(interval)
      beats.append(Beat(time: times[index], beatsPerMinute: 60 / interval, run: run))
      if let previous { successive.append(interval - previous) }
      previous = interval
    }
    self.beats = beats
    beatCount = times.count
    duration = (times.last ?? 0) - (times.first ?? 0)
    if intervals.isEmpty {
      averageBeatsPerMinute = nil
      sdnn = nil
    } else {
      let mean = intervals.reduce(0, +) / Double(intervals.count)
      averageBeatsPerMinute = 60 / mean
      sdnn =
        intervals.count > 1
        ? (intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
          / Double(intervals.count - 1)).squareRoot() * 1000
        : nil
    }
    rmssd =
      successive.isEmpty
      ? nil
      : (successive.map { $0 * $0 }.reduce(0, +) / Double(successive.count)).squareRoot() * 1000
  }
}

extension HealthHeartbeatSeries {
  /// Its beats' times (seconds since its start) and the beats that came after a gap. Gaps that
  /// can't be read leave no intervals rather than false ones across them: just the beat count.
  public var analysis: HeartbeatAnalysis {
    let decoder = JSONDecoder()
    let times = (try? decoder.decode([Double].self, from: Data(beats.utf8))) ?? []
    guard let gaps = try? decoder.decode([Int].self, from: Data(self.gaps.utf8)) else {
      return HeartbeatAnalysis(beats: times, gaps: Set(times.indices))
    }
    return HeartbeatAnalysis(beats: times, gaps: Set(gaps))
  }
}
