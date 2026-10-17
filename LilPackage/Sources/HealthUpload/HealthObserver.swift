public import Dependencies
import Foundation
import HealthKit
import HealthKitAccess
import IssueReporting

extension DependencyValues {
  /// Hears about changes to Health data, including while the app is in the background.
  public var healthObserver: HealthObserver {
    get { self[HealthObserver.self] }
    set { self[HealthObserver.self] = newValue }
  }
}

public struct HealthObserver: Sendable {
  /// Observes every type and turns on background delivery for it, at the most frequent schedule
  /// HealthKit allows each type (`.immediate`, which HealthKit limits per type, e.g. hourly for
  /// steps). `onChange` gets a changed type's identifier. Must be called at every launch, before
  /// HealthKit delivers the change that woke the app, and again after Health access is granted,
  /// to turn delivery on for types that weren't readable before.
  public var start:
    @Sendable (
      _ types: [HealthBackfillType], _ onChange: @escaping @Sendable (String) async -> Void
    ) async -> Void

  public init(
    start:
      @escaping @Sendable (
        _ types: [HealthBackfillType], _ onChange: @escaping @Sendable (String) async -> Void
      ) async -> Void
  ) {
    self.start = start
  }

  /// How long a background wake may take before HealthKit is told it's handled. The upload goes
  /// on if the app keeps running; anything unfinished is picked up by the next wake.
  static let completionDeadline: Duration = .seconds(25)
}

extension HealthObserver: DependencyKey {
  public static var liveValue: Self {
    let store = HKHealthStore()
    let observed = LockIsolated<Set<String>>([])
    /// Types whose query failed this launch, so each failure is logged once.
    let failed = LockIsolated<Set<String>>([])
    return Self { types, onChange in
      let sampleTypes = types.compactMap { type in type.sampleType.map { (type.id, $0) } }
      // Every query first, so each type is watched before any delivery is turned on. Calling
      // again (e.g. after Health access was granted) adds no second query for a type, unless
      // its query failed because Health hadn't been asked about it.
      for (id, sampleType) in sampleTypes where observed.withValue({ $0.insert(id).inserted }) {
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {
          query, completion, error in
          if let error {
            if failed.withValue({ $0.insert(id).inserted }) {
              BackfillLog.write(
                "observing \(BackfillLog.name(id)) failed: \(error.localizedDescription)")
            }
            // Not asked about yet, e.g. at a fresh install's launch. Stopped and forgotten, so the
            // next call (after access is granted) watches the type again. Other errors, such as
            // a locked device's, leave the query to HealthKit, as before.
            if (error as? HKError)?.code == .errorAuthorizationNotDetermined {
              store.stop(query)
              observed.withValue { _ = $0.remove(id) }
            }
            return completion()
          }
          let done = UncheckedSendable(completion)
          Task {
            await handle(id, onChange)
            done.value()
          }
        }
        store.execute(query)
      }
      // Fails for types the app may not read yet; it's turned on again after access is granted.
      await withTaskGroup(of: Void.self) { group in
        for (_, sampleType) in sampleTypes {
          group.addTask {
            try? await store.enableBackgroundDelivery(for: sampleType, frequency: .immediate)
          }
        }
      }
    }
  }

  /// Runs `onChange`, but returns after the deadline even if it's still going (it carries on).
  static func handle(
    _ type: String, deadline: Duration = completionDeadline,
    _ onChange: @escaping @Sendable (String) async -> Void
  ) async {
    let work = Task { await onChange(type) }
    let waiting = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    // Whichever comes first resumes; the other finds nothing to resume.
    let resume = { @Sendable in
      waiting.withValue {
        $0?.resume()
        $0 = nil
      }
    }
    await withCheckedContinuation { continuation in
      waiting.setValue(continuation)
      Task {
        await work.value
        resume()
      }
      Task {
        try? await Task.sleep(for: deadline)
        resume()
      }
    }
  }

  public static var testValue: Self {
    Self { _, _ in reportIssue("Unimplemented: @Dependency(\\.healthObserver).start") }
  }

  public static let previewValue = Self { _, _ in }
}

extension HealthBackfillType {
  /// The types on the iOS version the app runs on.
  public static var current: [Self] { all(availableOn: HealthAuthorization.currentVersion) }
}
