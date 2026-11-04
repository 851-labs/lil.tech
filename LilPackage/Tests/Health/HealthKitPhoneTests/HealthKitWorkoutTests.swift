import Foundation
import HealthKit
import HealthUpload
import Testing
import WorkoutKit

/// How the iPhone reads a workout out of HealthKit for its upload (`WorkoutRecord`, 851-4030):
/// each activity's configuration, where it was set up, and the WorkoutKit plan, which an app can't
/// attach on iOS (only the Watch's Workout app records one), so these workouts have none.
@Suite(.serialized)
struct HealthKitWorkoutTests {
  let start = Date(timeIntervalSince1970: 1_790_000_000)

  @Test
  func activitiesKeepWhereTheyWereSetUp() async throws {
    let health = try await SyntheticHealthKit.empty()
    let swim = configuration(.swimming, .indoor, swimming: .pool)
    let transition = configuration(.transition, .unknown)
    let ride = configuration(.cycling, .outdoor)
    let builder = HKWorkoutBuilder(
      healthStore: health.store, configuration: configuration(.swimBikeRun, .outdoor),
      device: nil)
    try await builder.beginCollection(at: start)
    for (index, configuration) in [swim, transition, ride].enumerated() {
      let from = start.addingTimeInterval(Double(index) * 600)
      try await builder.addWorkoutActivity(
        HKWorkoutActivity(
          workoutConfiguration: configuration, start: from, end: from.addingTimeInterval(600),
          metadata: nil))
    }
    try await builder.endCollection(at: start.addingTimeInterval(1800))
    let workout = try #require(try await builder.finishWorkout())

    let record = try await WorkoutRecord(workout)
    #expect(record.activities.map(\.activityType) == [46, 83, 13])
    #expect(
      record.activities.map(\.locationType) == [
        HKWorkoutSessionLocationType.indoor.rawValue, HKWorkoutSessionLocationType.unknown.rawValue,
        HKWorkoutSessionLocationType.outdoor.rawValue,
      ])
    #expect(
      record.activities.map(\.swimmingLocationType) == [
        HKWorkoutSwimmingLocationType.pool.rawValue, HKWorkoutSwimmingLocationType.unknown.rawValue,
        HKWorkoutSwimmingLocationType.unknown.rawValue,
      ])
    #expect(record.plan == nil)

    // As it goes up: each activity's location types, and no plan in the metadata.
    let row = try #require(HealthEncoder.workout(record).row)
    guard case .array(let activities) = row["activities"] else {
      Issue.record("No activities")
      return
    }
    let locations: [[JSONValue?]] = activities.map { activity in
      guard case .object(let object) = activity else { return [] }
      return [object["locationType"], object["swimmingLocationType"]]
    }
    let expected: [[JSONValue?]] = [
      [.number(2), .number(1)], [.number(1), .number(0)], [.number(3), .number(0)],
    ]
    #expect(locations == expected)
    if case .object(let metadata) = row["metadata"] {
      #expect(metadata[HealthEncoder.workoutPlanKey] == nil)
    }
  }

  @Test
  func aWorkoutWithoutAPlanHasNone() async throws {
    let health = try await SyntheticHealthKit.empty()
    let workout = try await health.workout(.running, at: start, minutes: 30)
    // HealthKit doesn't say "no plan" with nil, but with an error (`ImportError`, code 3),
    // which the reader takes for none.
    let error = await #expect(throws: (any Error).self) { try await workout.workoutPlan }
    #expect((error as? NSError)?.domain == "WorkoutKit.ImportError")
    let record = try await WorkoutRecord(workout)
    // Recorded without activities of its own, it may have one from its configuration.
    #expect(record.activities.count <= 1)
    #expect(record.activities.allSatisfy { $0.activityType == 37 })
    #expect(record.plan == nil)
  }

  private func configuration(
    _ activity: HKWorkoutActivityType, _ location: HKWorkoutSessionLocationType,
    swimming: HKWorkoutSwimmingLocationType = .unknown
  ) -> HKWorkoutConfiguration {
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = activity
    configuration.locationType = location
    configuration.swimmingLocationType = swimming
    if activity == .swimming {
      configuration.lapLength = HKQuantity(unit: .meter(), doubleValue: 25)
    }
    return configuration
  }
}
