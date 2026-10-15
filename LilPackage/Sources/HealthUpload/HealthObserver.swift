public import Dependencies
import Foundation
import HealthCatalog
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
  /// HealthKit delivers the change that woke the app.
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
    return Self { types, onChange in
      for type in types {
        let sampleType: HKSampleType? =
          type.isCorrelation
          ? HKObjectType.correlationType(forIdentifier: .init(rawValue: type.id))
          : HealthCatalog.type(id: type.id)?.objectType as? HKSampleType
        guard let sampleType else { continue }
        let id = type.id
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) {
          _, completion, error in
          guard error == nil else { return completion() }
          let done = UncheckedSendable(completion)
          Task {
            await handle(id, onChange)
            done.value()
          }
        }
        store.execute(query)
        do {
          try await store.enableBackgroundDelivery(for: sampleType, frequency: .immediate)
        } catch {
          reportIssue(error, "Background delivery for \(id)")
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
