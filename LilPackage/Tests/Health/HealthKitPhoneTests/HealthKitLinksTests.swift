import Foundation
import HealthKit
import HealthUpload
import Testing

/// What HealthKit links to a workout (851-4153), read for the upload: the samples added to it,
/// which the Mac charted by guessing from its time and source, and the effort scores related to
/// it. An ECG's symptoms are read the same way, but apps can't create ECGs, so only the package's
/// tests cover their encoding.
@Suite(.serialized)
struct HealthKitLinksTests {
  let start = Date(timeIntervalSince1970: 1_790_000_000)
  let workouts = HealthBackfillType(id: "HKWorkoutTypeIdentifier")

  /// A workout's samples are those added to it, by type: not another app's (or this one's)
  /// recorded at the same time. They go up with the workout, as a page reads it.
  @Test
  func aWorkoutGoesUpWithTheSamplesAddedToIt() async throws {
    let health = try await SyntheticHealthKit.empty()
    let (workout, added) = try await run(health)
    let other = heartRate(99, at: start.addingTimeInterval(120))
    try await health.save([other])

    let mutations = try await readAll(workouts)
    let id = workout.uuid.uuidString.lowercased()
    #expect(
      mutations.map { "\($0.entity) \($0.id)" } == [
        "health_workout \(id)", "health_workout_samples \(id)",
      ])
    let row = try #require(mutations.last?.row)
    #expect(row["count"] == 3)
    #expect(
      row["samples"]
        == .object([
          "HKQuantityTypeIdentifierHeartRate": .array(
            added.prefix(2).map { .string($0.uuid.uuidString.lowercased()) }),
          "HKQuantityTypeIdentifierActiveEnergyBurned": .array([
            .string(added[2].uuid.uuidString.lowercased())
          ]),
        ]))
  }

  /// Workouts uploaded before their links were (851-4153) have them read again, alone: no workout
  /// goes up again.
  @Test
  func readingAgainSendsOnlyTheLinks() async throws {
    let health = try await SyntheticHealthKit.empty()
    let (workout, _) = try await run(health)
    let mutations = try await readAll(workouts, links: true)
    #expect(
      mutations.map { "\($0.entity) \($0.id)" } == [
        "health_workout_samples \(workout.uuid.uuidString.lowercased())"
      ])
    #expect(mutations.first?.row?["count"] == 3)
  }

  /// A workout's effort scores, its own and a leg's, with the one HealthKit finds most relevant.
  /// A score needn't fall within its workout (this one's is an hour after it ends), so the Mac
  /// can't guess them by time (the sync audit's unclear item 4). Once unrelated, they're gone
  /// from the next read.
  @Test
  func effortScoresAreReadWithTheirLegs() async throws {
    let health = try await SyntheticHealthKit.empty()
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = .swimBikeRun
    let builder = HKWorkoutBuilder(
      healthStore: health.store, configuration: configuration, device: nil)
    try await builder.beginCollection(at: start)
    for (index, activity) in [HKWorkoutActivityType.swimming, .cycling].enumerated() {
      let leg = HKWorkoutConfiguration()
      leg.activityType = activity
      leg.locationType = .outdoor
      if activity == .swimming { leg.swimmingLocationType = .openWater }
      let from = start.addingTimeInterval(Double(index) * 600)
      try await builder.addWorkoutActivity(
        HKWorkoutActivity(
          workoutConfiguration: leg, start: from, end: from.addingTimeInterval(600),
          metadata: nil))
    }
    try await builder.endCollection(at: start.addingTimeInterval(1200))
    let workout = try #require(try await builder.finishWorkout())
    let swim = try #require(workout.workoutActivities.first)
    let later = effort(8, at: start.addingTimeInterval(4800))
    let first = effort(6, at: start.addingTimeInterval(1200))
    let leg = effort(5, at: start.addingTimeInterval(600))
    try await health.save([later, first, leg])
    try await relate(first, workout, health.store)
    try await relate(later, workout, health.store)
    try await relate(leg, workout, health.store, activity: swim)

    let read = try await HealthWorkoutEffortsReader.liveValue.read()
    let id = { (sample: HKSample) in JSONValue.string(sample.uuid.uuidString.lowercased()) }
    #expect(read.map(\.id) == [workout.uuid.uuidString.lowercased()])
    let row = try #require(read.first?.row)
    #expect(row["samples"] == .array([id(first), id(later)]))
    // The last related, it seems: not the latest by date, nor the highest.
    #expect(row["mostRelevant"] == id(later))
    // The cycling leg has no score of its own, so it's left out.
    #expect(
      row["legs"]
        == .array([
          .object([
            "activity": .string(swim.uuid.uuidString.lowercased()),
            "samples": .array([id(leg)]), "mostRelevant": id(leg),
          ])
        ]))

    try await unrelate(later, workout, health.store)
    try await unrelate(first, workout, health.store)
    try await unrelate(leg, workout, health.store, activity: swim)
    #expect(try await HealthWorkoutEffortsReader.liveValue.read().isEmpty)
  }

  /// Why effort scores are read whole every time (`HealthWorkoutEffortsReader`): relating one
  /// doesn't change its workout's anchor, and the relationships' own anchor reports one related
  /// since, but not one unrelated or deleted.
  @Test
  func anchorsMissEffortScoresUnrelatedOrDeleted() async throws {
    let health = try await SyntheticHealthKit.empty()
    let (workout, _) = try await run(health)
    let workoutAnchor = try await HKAnchoredObjectQueryDescriptor(
      predicates: [.workout()], anchor: nil
    ).result(for: health.store).newAnchor
    let before = try await relationships(after: nil, health.store)
    let kept = effort(7, at: start.addingTimeInterval(3600))
    let dropped = effort(4, at: start.addingTimeInterval(3600))
    try await health.save([kept, dropped])
    try await relate(kept, workout, health.store)
    try await relate(dropped, workout, health.store)

    let workoutsSince = try await HKAnchoredObjectQueryDescriptor(
      predicates: [.workout()], anchor: workoutAnchor
    ).result(for: health.store)
    #expect(workoutsSince.addedSamples.isEmpty)
    let related = try await relationships(after: before.newAnchor, health.store)
    #expect(related.relationships.flatMap { $0.samples ?? [] }.count == 2)

    try await unrelate(dropped, workout, health.store)
    let afterUnrelating = try await relationships(after: related.newAnchor, health.store)
    #expect(afterUnrelating.relationships.isEmpty)
    try await health.store.delete(kept)
    let afterDeleting = try await relationships(after: afterUnrelating.newAnchor, health.store)
    #expect(afterDeleting.relationships.isEmpty)
    // Read whole, the workout has none left.
    #expect(try await relationships(after: nil, health.store).relationships.isEmpty)
  }

  /// A 10-minute run with two heart rates and an energy sample added to it, returned in that
  /// order.
  private func run(_ health: SyntheticHealthKit) async throws -> (HKWorkout, [HKQuantitySample]) {
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = .running
    let builder = HKWorkoutBuilder(
      healthStore: health.store, configuration: configuration, device: nil)
    try await builder.beginCollection(at: start)
    let added = [
      heartRate(120, at: start), heartRate(130, at: start.addingTimeInterval(60)),
      SyntheticHealthKit.sample(
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, 10, at: start, minutes: 1),
    ]
    try await builder.addSamples(added)
    try await builder.endCollection(at: start.addingTimeInterval(600))
    return (try #require(try await builder.finishWorkout()), added)
  }

  private func heartRate(_ value: Double, at date: Date) -> HKQuantitySample {
    SyntheticHealthKit.sample(HKQuantityTypeIdentifier.heartRate.rawValue, value, at: date)
  }

  private func effort(_ value: Double, at date: Date) -> HKQuantitySample {
    HKQuantitySample(
      type: HKQuantityType(.workoutEffortScore),
      quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: value), start: date, end: date)
  }

  private func relationships(after anchor: HKQueryAnchor?, _ store: HKHealthStore) async throws
    -> HKWorkoutEffortRelationshipQueryDescriptor.Result
  {
    try await HKWorkoutEffortRelationshipQueryDescriptor(
      predicate: nil, anchor: anchor, option: .default
    ).result(for: store)
  }

  private func relate(
    _ sample: HKSample, _ workout: HKWorkout, _ store: HKHealthStore,
    activity: HKWorkoutActivity? = nil
  ) async throws {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      store.relateWorkoutEffortSample(sample, with: workout, activity: activity) { _, error in
        if let error { done.resume(throwing: error) } else { done.resume() }
      }
    }
  }

  private func unrelate(
    _ sample: HKSample, _ workout: HKWorkout, _ store: HKHealthStore,
    activity: HKWorkoutActivity? = nil
  ) async throws {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      store.unrelateWorkoutEffortSample(sample, from: workout, activity: activity) { _, error in
        if let error { done.resume(throwing: error) } else { done.resume() }
      }
    }
  }

  /// Every page of a type, as the backfill reads it, or of its links alone (`links`).
  private func readAll(_ type: HealthBackfillType, links: Bool = false) async throws
    -> [HealthMutation]
  {
    var mutations: [HealthMutation] = []
    var anchor: Data?
    while true {
      let page =
        links
        ? try await HealthReader.liveValue.series(type, anchor, 500)
        : try await HealthReader.liveValue.page(type, anchor, 500)
      mutations += page.mutations
      anchor = page.anchor
      if !page.hasMore { break }
    }
    return mutations.filter { $0.op == .upsert }
  }
}
