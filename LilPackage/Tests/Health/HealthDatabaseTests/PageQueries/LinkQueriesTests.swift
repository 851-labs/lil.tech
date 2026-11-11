import Foundation
import HealthDatabase
import SQLiteData
import Testing

// Synthetic data only (AGENTS.md): made-up samples and links (851-4186).

private let heartRate = HealthDatabase.heartRateType
private let energy = "HKQuantityTypeIdentifierActiveEnergyBurned"

private func sample(
  _ id: String, _ type: String = heartRate, at start: Int, value: Double = 120
) -> HealthSample {
  HealthSample(
    id: id, type: type, startDate: start, endDate: start, value: value, unit: "count/min",
    sourceName: "Test", sourceBundleID: "com.example")
}

@Suite
struct LinkQueriesTests {
  let database: any DatabaseWriter

  init() throws {
    database = try HealthDatabase.make()
    try database.write { db in
      try HealthSample.insert {
        sample("hr2", at: 2_000)
        sample("hr1", at: 1_000)
        // Recorded during the workout, but not added to it.
        sample("hr-other", at: 1_500)
        sample("kcal", energy, at: 1_000)
        sample("effort-early", HealthDatabase.workoutEffortScoreType, at: 5_000, value: 5)
        sample("effort-late", HealthDatabase.workoutEffortScoreType, at: 9_000, value: 8)
        sample("leg", HealthDatabase.estimatedWorkoutEffortScoreType, at: 6_000, value: 6)
      }
      .execute(db)
    }
  }

  /// Linked samples are those its record names that have arrived, of the types asked for, in
  /// order of start: not another sample at the same time, nor one that hasn't synced.
  @Test
  func linkedSamplesAreThoseTheRecordNames() throws {
    try database.write { db in
      try HealthWorkoutSamples.insert {
        HealthWorkoutSamples(
          id: "w", count: 4,
          samples: #"{"\#(heartRate)":["hr2","hr1","hr-missing"],"\#(energy)":["kcal"]}"#)
      }
      .execute(db)
    }
    let heartRates = try database.read { db in
      try HealthDatabase.linkedSamples(ofWorkout: "w", types: [heartRate], db)
    }
    #expect(heartRates.samples?.map(\.id) == ["hr1", "hr2"])
    let all = try database.read { db in try HealthDatabase.linkedSamples(ofWorkout: "w", db) }
    #expect(all.samples?.map(\.id) == ["hr1", "kcal", "hr2"])
  }

  /// No record is `notSynced`, and a record without IDs `tooMany`, each for readers to fall back
  /// on; an empty one is linked to nothing.
  @Test
  func aMissingOrTooBigRecordIsntLinked() throws {
    try database.write { db in
      try HealthWorkoutSamples.insert {
        HealthWorkoutSamples(id: "big", count: 25_000, samples: nil)
        HealthWorkoutSamples(id: "empty", count: 0, samples: "{}")
        // Not what the server documents: read as not synced, so readers fall back.
        HealthWorkoutSamples(id: "odd", count: 1, samples: #"["hr1"]"#)
      }
      .execute(db)
    }
    let (missing, big, empty, odd) = try database.read { db in
      (
        try HealthDatabase.linkedSamples(ofWorkout: "none", db),
        try HealthDatabase.linkedSamples(ofWorkout: "big", db),
        try HealthDatabase.linkedSamples(ofWorkout: "empty", db),
        try HealthDatabase.linkedSamples(ofWorkout: "odd", db)
      )
    }
    #expect(missing == .notSynced)
    #expect(big == .tooMany(count: 25_000))
    #expect(empty == .linked([]))
    #expect(odd == .notSynced)
  }

  @Test
  func anECGsSymptoms() throws {
    let symptom = "HKCategoryTypeIdentifierDizziness"
    try database.write { db in
      try HealthSample.insert {
        HealthSample(
          id: "s1", type: symptom, startDate: 0, endDate: 30_000, categoryValue: 2,
          sourceName: "Test", sourceBundleID: "com.example")
      }
      .execute(db)
      try HealthElectrocardiogramSymptoms.insert {
        HealthElectrocardiogramSymptoms(id: "ecg", count: 1, samples: #"{"\#(symptom)":["s1"]}"#)
      }
      .execute(db)
    }
    let (linked, missing) = try database.read { db in
      (
        try HealthDatabase.symptoms(ofElectrocardiogram: "ecg", db),
        try HealthDatabase.symptoms(ofElectrocardiogram: "other", db)
      )
    }
    #expect(linked.samples?.map(\.id) == ["s1"])
    #expect(missing == .notSynced)
  }

  /// The most relevant score stands for the workout, else the latest rated one that has arrived,
  /// else the latest estimate, and each leg has its own.
  @Test
  func effortScores() throws {
    try database.write { db in
      try HealthWorkoutEffort.insert {
        HealthWorkoutEffort(
          id: "w", samples: #"["effort-early","effort-late"]"#, mostRelevant: "effort-early",
          legs: #"[{"activity":"a1","samples":["leg"],"mostRelevant":"leg"}]"#)
        // Its most relevant score hasn't arrived.
        HealthWorkoutEffort(
          id: "w2", samples: #"["effort-early","effort-late","missing"]"#,
          mostRelevant: "missing", legs: "[]")
        // A later estimate doesn't stand in for a rated score.
        HealthWorkoutEffort(
          id: "w3", samples: #"["effort-early","leg","missing"]"#, mostRelevant: "missing",
          legs: "[]")
      }
      .execute(db)
    }
    let (effort, second, third, none) = try database.read { db in
      (
        try HealthDatabase.workoutEffort(of: "w", db),
        try HealthDatabase.workoutEffort(of: "w2", db),
        try HealthDatabase.workoutEffort(of: "w3", db),
        try HealthDatabase.workoutEffort(of: "none", db)
      )
    }
    #expect(effort?.score?.id == "effort-early")
    #expect(effort?.legs.mapValues(\.id) == ["a1": "leg"])
    #expect(second?.score?.id == "effort-late")
    #expect(third?.score?.id == "effort-early")
    #expect(none == nil)
  }

  /// A workout's activities keep their IDs, which effort scores' legs name.
  @Test
  func activitiesKeepTheirIDs() {
    let workout = HealthWorkout(
      id: "w", activityType: 82, startDate: 0, endDate: 60_000, duration: 60,
      activities:
        #"[{"id":"a1","activityType":46,"startDate":0,"endDate":30000,"duration":30},"#
        + #"{"activityType":37,"startDate":30000,"endDate":60000,"duration":30}]"#,
      events: "[]", statistics: "{}", sourceName: "Test", sourceBundleID: "com.example")
    #expect(workout.decodedActivities.map(\.id) == ["a1", nil])
  }
}
