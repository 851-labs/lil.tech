import Foundation
import HealthKit

/// What the cards' conformance source apps do (`ConformanceSourceApps`, 851-3201): launched with
/// `-writeConformance`, a copy of the host deletes what it wrote before, then writes its source's
/// samples and workouts from the dataset (`ConformanceSamples`); with `-deleteConformance`, it only
/// deletes. It says what it did on standard error, and exits, with 0 when it worked.
/// `scripts/test-iphone-healthkit` launches each with `simctl launch --console`, once
/// `GrantHealthAccess` has given it access.
enum ConformanceWriter {
  static func run(writing: Bool) async -> Int32 {
    do {
      let summary = try await write(writing: writing)
      log(summary)
      return 0
    } catch {
      log("error: \(error)")
      return 1
    }
  }

  private static func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
  }

  private struct Failure: Error, CustomStringConvertible {
    var description: String
  }

  private static func write(writing: Bool) async throws -> String {
    let store = HKHealthStore()
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    guard let number = ConformanceSourceApps.number(of: bundleID) else {
      throw Failure(description: "\(bundleID) isn't one of the conformance source apps.")
    }
    for type in TestHealthTypes.all where store.authorizationStatus(for: type) != .sharingAuthorized
    {
      throw Failure(
        description: "No access to \(type.identifier): GrantHealthAccess gives it first.")
    }
    for type in TestHealthTypes.all {
      try await deleteAll(of: type, in: store)
    }
    guard writing else { return "Deleted what \(bundleID) wrote." }

    let dataset = try ConformanceSamples.cards()
    guard number <= dataset.sources.count else {
      throw Failure(
        description: "The dataset has \(dataset.sources.count) sources, so no app \(number).")
    }
    let source = dataset.sources[number - 1]
    let part = dataset.of(source: source).only(types: TestHealthTypes.identifiers)
    let samples = try samples(part.samples)
    if !samples.isEmpty {
      try await store.save(samples)
    }
    for workout in part.workouts {
      func configuration(
        _ activityType: Int, locationType: Int? = nil, swimmingLocationType: Int? = nil
      ) throws -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        guard let activity = HKWorkoutActivityType(rawValue: UInt(activityType)) else {
          throw Failure(description: "Workout \(workout.id): no activity \(activityType)")
        }
        configuration.activityType = activity
        if let location = locationType.flatMap(HKWorkoutSessionLocationType.init(rawValue:)) {
          configuration.locationType = location
        }
        if let swimming = swimmingLocationType.flatMap(
          HKWorkoutSwimmingLocationType.init(rawValue:))
        {
          configuration.swimmingLocationType = swimming
        }
        // A pool swim needs a lap length, and HealthKit refuses one for open water.
        if activity == .swimming, configuration.swimmingLocationType == .pool {
          configuration.lapLength = HKQuantity(unit: .meter(), doubleValue: 25)
        }
        return configuration
      }
      // Where it was, as the cards' workout windows read it (851-4031): its metadata's
      // `HKIndoorWorkout`, and its activities' configurations and metadata.
      func metadata(_ indoor: NSNumber?) -> [String: Any]? {
        indoor.map { [HKMetadataKeyIndoorWorkout: $0] }
      }
      let builder = HKWorkoutBuilder(
        healthStore: store, configuration: try configuration(workout.activityType), device: nil)
      try await builder.beginCollection(at: date(workout.start))
      if let metadata = metadata(workout.indoor) {
        try await builder.addMetadata(metadata)
      }
      for activity in workout.activities {
        try await builder.addWorkoutActivity(
          HKWorkoutActivity(
            workoutConfiguration: try configuration(
              activity.activityType, locationType: activity.locationType,
              swimmingLocationType: activity.swimmingLocationType),
            start: date(activity.start), end: activity.end.map(date),
            metadata: metadata(activity.indoor)))
      }
      try await builder.endCollection(at: date(workout.end))
      guard try await builder.finishWorkout() != nil else {
        throw Failure(description: "Workout \(workout.id) wasn't saved.")
      }
    }
    // HealthKit gives a sample the source of the app that saved it, which the cases need to be
    // this app's alone.
    if let first = samples.first {
      let saved = try await HKSampleQueryDescriptor(
        predicates: [
          .sample(type: first.sampleType, predicate: HKQuery.predicateForObject(with: first.uuid))
        ],
        sortDescriptors: []
      )
      .result(for: store)
      let savedSource = saved.first?.sourceRevision.source.bundleIdentifier
      guard savedSource == bundleID else {
        throw Failure(
          description:
            "HealthKit gave the samples the source \(savedSource ?? "none"), not \(bundleID).")
      }
    }
    return
      "Wrote \(samples.count) samples and \(part.workouts.count) workouts of \(source) as \(bundleID)."
  }

  /// `deleteObjects` fails when there's nothing to delete.
  private static func deleteAll(of type: HKSampleType, in store: HKHealthStore) async throws {
    let mine = HKQuery.predicateForObjects(from: .default())
    let existing = try await HKSampleQueryDescriptor(
      predicates: [.sample(type: type, predicate: mine)], sortDescriptors: [], limit: 1
    )
    .result(for: store)
    guard !existing.isEmpty else { return }
    _ = try await store.deleteObjects(of: type, predicate: mine)
  }

  /// The samples as HealthKit's. HealthKit gives each a new ID, so samples that tie on start and
  /// end (which `first` and `latest` break by ID) are made again until their IDs sort as the
  /// dataset's do.
  private static func samples(_ samples: [ConformanceSamples.Sample]) throws -> [HKSample] {
    var made = try samples.map(sample)
    let ties = Dictionary(grouping: samples.indices) {
      "\(samples[$0].type) \(samples[$0].start) \(samples[$0].end)"
    }
    for indices in ties.values where indices.count > 1 {
      let byID = indices.sorted { samples[$0].id < samples[$1].id }
      var attempts = 0
      while byID.map({ made[$0].uuid.uuidString.lowercased() })
        != byID.map({ made[$0].uuid.uuidString.lowercased() }).sorted()
      {
        attempts += 1
        guard attempts < 1000 else {
          throw Failure(
            description: "Couldn't order the IDs of samples \(byID.map { samples[$0].id }).")
        }
        for index in indices {
          made[index] = try sample(samples[index])
        }
      }
    }
    return made
  }

  private static func sample(_ sample: ConformanceSamples.Sample) throws -> HKSample {
    let device = sample.device.map {
      HKDevice(
        name: $0.name, manufacturer: $0.manufacturer, model: $0.model,
        hardwareVersion: $0.hardwareVersion, firmwareVersion: nil,
        softwareVersion: $0.softwareVersion, localIdentifier: nil, udiDeviceIdentifier: nil)
    }
    let (start, end) = (date(sample.start), date(sample.end))
    if let categoryValue = sample.categoryValue {
      return HKCategorySample(
        type: HKCategoryType(HKCategoryTypeIdentifier(rawValue: sample.type)),
        value: categoryValue, start: start, end: end, device: device, metadata: nil)
    }
    guard let value = sample.value, let unit = sample.unit else {
      throw Failure(description: "Sample \(sample.id) has no value, or no unit.")
    }
    return HKQuantitySample(
      type: HKQuantityType(HKQuantityTypeIdentifier(rawValue: sample.type)),
      quantity: HKQuantity(unit: HKUnit(from: unit), doubleValue: value), start: start, end: end,
      device: device, metadata: nil)
  }

  private static func date(_ milliseconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }
}
