public import Foundation
import SQLiteData

/// Heart rate while asleep last night (851-3110): its range every 15 minutes from falling asleep
/// to waking, and the lowest and highest readings.
public struct SleepHeartRate: Equatable, Sendable {
  /// One stretch's lowest and highest readings.
  public struct Range: Equatable, Sendable {
    public var start: Date
    public var minimum: Double
    public var maximum: Double

    public init(start: Date, minimum: Double, maximum: Double) {
      self.start = start
      self.minimum = minimum
      self.maximum = maximum
    }
  }

  /// When the night's sleep started and ended.
  public var start: Date
  public var end: Date
  /// The stretches with readings, oldest first.
  public let ranges: [Range]
  /// The lowest and highest readings.
  public let minimum: Double
  public let maximum: Double

  public init(start: Date, end: Date, ranges: [Range]) {
    self.start = start
    self.end = end
    self.ranges = ranges
    minimum = ranges.map(\.minimum).min() ?? 0
    maximum = ranges.map(\.maximum).max() ?? 0
  }

  /// Each range's span.
  public static let interval: TimeInterval = 15 * 60
  /// Readings it needs while asleep: a Watch takes one every few minutes, so ten is about an
  /// hour's, enough for a range to say something.
  public static let minimumReadings = 10
}

extension HealthDatabase {
  /// Every source's heart rate readings that start in one of `night`'s stretches asleep, so not
  /// while lying awake, or up in the night, a range every 15 minutes from falling asleep. `nil`
  /// under `minimumReadings`.
  static func sleepHeartRate(during night: SleepNight, _ db: Database) throws -> SleepHeartRate? {
    let asleep = night.segments.filter(\.stage.isAsleep)
    guard let start = asleep.map(\.start).min(), let end = asleep.map(\.end).max() else {
      return nil
    }
    let (lower, upper) = (start.unixMilliseconds, end.unixMilliseconds)
    let readings =
      try HealthSample
      .where {
        $0.type.eq(heartRateType) && $0.startDate >= lower && $0.startDate < upper
          && $0.value.isNot(nil)
      }
      .order(by: \.startDate)
      .select { ($0.startDate, $0.value) }
      .fetchAll(db)
      .compactMap { start, value in value.map { (start: start, value: $0) } }
      .filter { reading in
        asleep.contains {
          $0.start.unixMilliseconds <= reading.start && reading.start < $0.end.unixMilliseconds
        }
      }
    guard readings.count >= SleepHeartRate.minimumReadings else { return nil }
    let interval = Int(SleepHeartRate.interval * 1000)
    var ranges: [SleepHeartRate.Range] = []
    for reading in readings {
      let bin = Date(unixMilliseconds: lower + (reading.start - lower) / interval * interval)
      if ranges.last?.start == bin {
        ranges[ranges.count - 1].minimum = min(ranges[ranges.count - 1].minimum, reading.value)
        ranges[ranges.count - 1].maximum = max(ranges[ranges.count - 1].maximum, reading.value)
      } else {
        ranges.append(.init(start: bin, minimum: reading.value, maximum: reading.value))
      }
    }
    return SleepHeartRate(start: start, end: end, ranges: ranges)
  }
}
