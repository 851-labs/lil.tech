import Foundation
import HealthCards
import HealthCatalog
import HealthKit
import Testing

/// Synthetic samples in the simulator's HealthKit, for the iPhone's HealthKit tests (851-3199):
/// each test starts from none, writes its own, and reads them back through the engine. Only this
/// app's samples are deleted, and only in the simulator `scripts/test-iphone-healthkit` makes.
struct SyntheticHealthKit {
  let store = HKHealthStore()

  /// Starts a test from an empty HealthKit: every sample of the tests' types this app wrote is
  /// deleted. Fails when access wasn't granted (`GrantHealthAccess`).
  static func empty() async throws -> SyntheticHealthKit {
    let health = SyntheticHealthKit()
    for type in TestHealthTypes.all {
      try #require(
        health.store.authorizationStatus(for: type) == .sharingAuthorized,
        "No access to \(type.identifier): run scripts/test-iphone-healthkit, which grants it.")
    }
    for type in TestHealthTypes.all {
      try await health.deleteAll(of: type)
    }
    return health
  }

  private func deleteAll(of type: HKSampleType) async throws {
    // `deleteObjects` fails when there's nothing to delete.
    let existing = try await HKSampleQueryDescriptor(
      predicates: [.sample(type: type, predicate: HKQuery.predicateForObjects(from: .default()))],
      sortDescriptors: [], limit: 1
    )
    .result(for: store)
    guard !existing.isEmpty else { return }
    _ = try await store.deleteObjects(
      of: type, predicate: HKQuery.predicateForObjects(from: .default()))
  }

  /// Saves samples, a batch at a time.
  func save(_ samples: [HKSample]) async throws {
    for start in stride(from: 0, to: samples.count, by: 10_000) {
      try await store.save(Array(samples[start..<min(start + 10_000, samples.count)]))
    }
  }

  /// A sample of a type in its catalog unit, from `start` for `minutes`.
  static func sample(
    _ typeID: String, _ value: Double, at start: Date, minutes: Double = 0, device: HKDevice? = nil
  ) -> HKQuantitySample {
    let type = HKQuantityType(HKQuantityTypeIdentifier(rawValue: typeID))
    let unit = HKUnit(from: HealthCatalog.type(id: typeID)!.unit!)
    return HKQuantitySample(
      type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: start,
      end: start.addingTimeInterval(minutes * 60), device: device, metadata: nil)
  }

  /// The samples as the core's readings, by type and oldest first, for the in-memory engine the
  /// HealthKit engine is compared with (`reference(_:samples:)`).
  static func readings(_ samples: [HKQuantitySample]) -> [String: [CardReading]] {
    var readings: [String: [CardReading]] = [:]
    for sample in samples {
      let id = sample.quantityType.identifier
      let unit = HKUnit(from: HealthCatalog.type(id: id)!.unit!)
      readings[id, default: []].append(
        CardReading(
          start: ms(sample.startDate), end: ms(sample.endDate),
          value: sample.quantity.doubleValue(for: unit),
          source: Bundle.main.bundleIdentifier!,
          sampleID: sample.uuid.uuidString.lowercased()))
    }
    return readings.mapValues { $0.sorted { $0.start < $1.start } }
  }
}

func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
