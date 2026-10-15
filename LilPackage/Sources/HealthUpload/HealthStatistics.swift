public import Dependencies
public import Foundation
import HealthCatalog
import HealthKit
import IssueReporting

#if canImport(WatchConnectivity) && os(iOS)
  import WatchConnectivity
#endif

/// One 30-minute bucket's sum, in the type's catalog unit.
public struct HealthBucket: Equatable, Sendable {
  public var start: Date
  public var sum: Double

  public init(start: Date, sum: Double) {
    self.start = start
    self.sum = sum
  }
}

extension HealthEncoder {
  public static let statisticEntity = "health_statistic"
  public static let statisticsDeviceEntity = "health_statistics_device"

  /// Statistics buckets are 30 minutes, starting on UTC half-hours.
  public static let bucketSeconds: TimeInterval = 1800

  /// A bucket's sum. The server stamps it with this iPhone (`docs/SYNC.md`).
  public static func statistic(type: String, bucket: HealthBucket, unit: String) -> HealthMutation {
    let start = Int(milliseconds(bucket.start))
    return .upsert(
      statisticEntity, id: "\(type)@\(start)",
      row: [
        "type": .string(type), "bucketStart": .number(Double(start)), "sum": .number(bucket.sum),
        "unit": .string(unit),
      ])
  }

  /// This iPhone's statistics status. The server sets when it reported.
  public static func statisticsDevice(pairedWithWatch: Bool) -> HealthMutation {
    .upsert(statisticsDeviceEntity, id: "self", row: ["pairedWithWatch": .bool(pairedWithWatch)])
  }

  /// The start of the bucket `date` falls in.
  public static func bucketStart(of date: Date) -> Date {
    Date(
      timeIntervalSince1970: (date.timeIntervalSince1970 / bucketSeconds).rounded(.down)
        * bucketSeconds)
  }
}

extension DependencyValues {
  /// HealthKit's own 30-minute sums, which de-duplicate overlapping sources like Health does.
  public var healthStatisticsReader: HealthStatisticsReader {
    get { self[HealthStatisticsReader.self] }
    set { self[HealthStatisticsReader.self] = newValue }
  }
}

public struct HealthStatisticsReader: Sendable {
  /// A cumulative type's non-empty 30-minute buckets from `start` to `end`.
  public var buckets:
    @Sendable (_ type: String, _ start: Date, _ end: Date) async throws -> [HealthBucket]
  /// Whether this iPhone is paired with an Apple Watch.
  public var isPairedWithWatch: @Sendable () async -> Bool

  public init(
    buckets:
      @escaping @Sendable (_ type: String, _ start: Date, _ end: Date) async throws
      -> [HealthBucket],
    isPairedWithWatch: @escaping @Sendable () async -> Bool
  ) {
    self.buckets = buckets
    self.isPairedWithWatch = isPairedWithWatch
  }
}

extension HealthStatisticsReader: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    return Self(
      buckets: { id, start, end in
        guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: id)),
          let unit = HealthCatalog.type(id: id)?.unit.map(HKUnit.init(from:))
        else { return [] }
        let descriptor = HKStatisticsCollectionQueryDescriptor(
          predicate: .quantitySample(
            type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
          options: .cumulativeSum,
          // From the Unix epoch in 30-minute steps: buckets start on UTC half-hours.
          anchorDate: Date(timeIntervalSince1970: 0),
          intervalComponents: DateComponents(minute: 30))
        let collection: HKStatisticsCollection
        do {
          collection = try await descriptor.result(for: store)
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
          throw HealthReader.Locked()
        }
        var buckets: [HealthBucket] = []
        collection.enumerateStatistics(from: start, to: end) { statistics, _ in
          if let sum = statistics.sumQuantity() {
            buckets.append(
              HealthBucket(start: statistics.startDate, sum: sum.doubleValue(for: unit)))
          }
        }
        return buckets
      },
      isPairedWithWatch: {
        #if canImport(WatchConnectivity) && os(iOS)
          return await WatchPairing.shared.isPaired()
        #else
          return false
        #endif
      }
    )
  }

  public static var testValue: Self {
    Self(
      buckets: { _, _, _ in
        reportIssue("Unimplemented: @Dependency(\\.healthStatisticsReader).buckets")
        return []
      },
      isPairedWithWatch: { false }
    )
  }
}

#if canImport(WatchConnectivity) && os(iOS)
  /// `WCSession.isPaired`, which is only known once the session is activated.
  private final class WatchPairing: NSObject, WCSessionDelegate, Sendable {
    static let shared = WatchPairing()
    /// Gives up after a few seconds, so a callback that never comes can't stop uploads.
    static let timeout: Duration = .seconds(5)

    private let waiting = LockIsolated<[CheckedContinuation<Bool, Never>]>([])

    func isPaired() async -> Bool {
      guard WCSession.isSupported() else { return false }
      let session = WCSession.default
      if session.activationState == .activated { return session.isPaired }
      return await withCheckedContinuation { continuation in
        waiting.withValue { $0.append(continuation) }
        session.delegate = self
        session.activate()
        Task {
          try? await Task.sleep(for: Self.timeout)
          let session = WCSession.default
          self.finish(paired: session.activationState == .activated && session.isPaired)
        }
      }
    }

    private func finish(paired: Bool) {
      let continuations = waiting.withValue {
        defer { $0 = [] }
        return $0
      }
      for continuation in continuations { continuation.resume(returning: paired) }
    }

    func session(
      _ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
      error: (any Error)?
    ) {
      finish(paired: state == .activated && session.isPaired)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
  }
#endif
