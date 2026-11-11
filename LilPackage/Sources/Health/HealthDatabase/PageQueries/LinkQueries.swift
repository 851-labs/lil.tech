import Foundation
public import SQLiteData

/// What a workout's or an ECG's link record (851-4153) says of the samples linked to it, as its
/// pages and tools read it.
public enum LinkedSamples: Equatable, Sendable {
  /// No record: an iPhone on a build from before 851-4153 uploaded it, or its links haven't
  /// synced yet. Readers fall back to what they did before (a workout's samples by its time).
  case notSynced
  /// More were linked than the iPhone uploads (20,000, `HealthEncoder.maxLinkedSamples`): only
  /// how many. Readers fall back as for `notSynced`.
  case tooMany(count: Int)
  /// Those linked that have arrived, of the types asked for, in order of start, then ID: maybe
  /// none. Linked samples are ordinary `health_sample` records, which may arrive later or be gone.
  case linked([HealthSample])

  /// The samples linked, or nil when the links aren't known.
  public var samples: [HealthSample]? {
    if case .linked(let samples) = self { samples } else { nil }
  }
}

/// A workout's effort scores, as its `health_workout_effort` record links them: the IDs of
/// `WorkoutEffortScore` and `EstimatedWorkoutEffortScore` samples.
public struct WorkoutEffortLinks: Equatable, Sendable {
  /// One of a multisport workout's legs with scores of its own.
  public struct Leg: Codable, Equatable, Sendable {
    /// The leg's ID in the workout's `activities` (``WorkoutActivityRecord/id``).
    public var activity: String
    public var samples: [String]
    public var mostRelevant: String?

    public init(activity: String, samples: [String], mostRelevant: String?) {
      self.activity = activity
      self.samples = samples
      self.mostRelevant = mostRelevant
    }
  }

  /// The whole workout's, in order of start, then ID.
  public var samples: [String]
  /// The one HealthKit finds most relevant.
  public var mostRelevant: String?
  public var legs: [Leg]

  public init(samples: [String], mostRelevant: String?, legs: [Leg]) {
    self.samples = samples
    self.mostRelevant = mostRelevant
    self.legs = legs
  }
}

/// A workout's effort scores, as its page shows them: one sample for the workout, and one for
/// each leg with its own.
public struct WorkoutEffort: Equatable, Sendable {
  /// The workout's score (``HealthDatabase/effortScore(_:mostRelevant:_:)``), nil if none of its
  /// scores has arrived.
  public var score: HealthSample?
  /// Each leg's, by its activity's ID.
  public var legs: [String: HealthSample]

  public init(score: HealthSample?, legs: [String: HealthSample] = [:]) {
    self.score = score
    self.legs = legs
  }
}

extension HealthWorkoutSamples {
  /// Its samples' IDs by type, each in order of start; nil when there were too many to upload,
  /// or the JSON can't be read.
  public var decodedSamples: [String: [String]]? { HealthDatabase.linkedIDs(samples) }
}

extension HealthElectrocardiogramSymptoms {
  /// Its symptoms' IDs by type, as ``HealthWorkoutSamples/decodedSamples`` reads a workout's.
  public var decodedSamples: [String: [String]]? { HealthDatabase.linkedIDs(samples) }
}

extension HealthWorkoutEffort {
  /// What it links, or nil if its JSON can't be read.
  public var decoded: WorkoutEffortLinks? {
    let decoder = JSONDecoder()
    guard
      let samples = try? decoder.decode([String].self, from: Data(samples.utf8)),
      let legs = try? decoder.decode([WorkoutEffortLinks.Leg].self, from: Data(legs.utf8))
    else { return nil }
    return WorkoutEffortLinks(samples: samples, mostRelevant: mostRelevant, legs: legs)
  }
}

extension HealthDatabase {
  public static let workoutEffortScoreType = "HKQuantityTypeIdentifierWorkoutEffortScore"
  public static let estimatedWorkoutEffortScoreType =
    "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore"

  /// The samples of `types` (all of them if nil) its app added to the workout with ID
  /// `workoutID`, as its `healthWorkoutSamples` record links them.
  public static func linkedSamples(
    ofWorkout workoutID: String, types: Set<String>? = nil, _ db: Database
  ) throws -> LinkedSamples {
    guard let record = try HealthWorkoutSamples.find(workoutID).fetchOne(db) else {
      return .notSynced
    }
    return try linkedSamples(record.decodedSamples, count: record.count, types: types, db)
  }

  /// The symptoms logged with the ECG with ID `electrocardiogramID`, as its
  /// `healthElectrocardiogramSymptoms` record links them.
  public static func symptoms(
    ofElectrocardiogram electrocardiogramID: String, _ db: Database
  ) throws -> LinkedSamples {
    guard let record = try HealthElectrocardiogramSymptoms.find(electrocardiogramID).fetchOne(db)
    else { return .notSynced }
    return try linkedSamples(record.decodedSamples, count: record.count, types: nil, db)
  }

  /// The workout's effort scores, nil if it has no `healthWorkoutEffort` record: it has none, or
  /// they haven't synced (the record only exists for workouts with scores, so the two can't be
  /// told apart).
  public static func workoutEffort(of workoutID: String, _ db: Database) throws -> WorkoutEffort? {
    guard let links = try HealthWorkoutEffort.find(workoutID).fetchOne(db)?.decoded else {
      return nil
    }
    var legs: [String: HealthSample] = [:]
    for leg in links.legs {
      legs[leg.activity] = try effortScore(leg.samples, mostRelevant: leg.mostRelevant, db)
    }
    return WorkoutEffort(
      score: try effortScore(links.samples, mostRelevant: links.mostRelevant, db), legs: legs)
  }

  /// The score that stands for a workout or a leg among those related to it: the one HealthKit
  /// finds most relevant, else (it hasn't arrived) the latest that has.
  public static func effortScore(
    _ ids: [String], mostRelevant: String?, _ db: Database
  ) throws -> HealthSample? {
    let samples = try samples(ids: ids, db)
    return samples.first { $0.id == mostRelevant } ?? samples.last
  }

  /// The samples with these IDs that have arrived, in order of start, then ID.
  public static func samples(ids: some Collection<String>, _ db: Database) throws
    -> [HealthSample]
  {
    var samples: [HealthSample] = []
    // A chunk at a time, well under SQLite's limit on a statement's variables.
    let ids = Array(ids)
    for start in stride(from: 0, to: ids.count, by: 500) {
      let chunk = Array(ids[start..<min(start + 500, ids.count)])
      samples += try HealthSample.where { $0.id.in(chunk) }.fetchAll(db)
    }
    return samples.sorted { ($0.startDate, $0.id) < ($1.startDate, $1.id) }
  }

  /// A link record's `samples` JSON: an object of type identifiers to arrays of IDs.
  static func linkedIDs(_ json: String?) -> [String: [String]]? {
    json.flatMap { try? JSONDecoder().decode([String: [String]].self, from: Data($0.utf8)) }
  }

  private static func linkedSamples(
    _ ids: [String: [String]]?, count: Int, types: Set<String>?, _ db: Database
  ) throws -> LinkedSamples {
    guard let ids else { return .tooMany(count: count) }
    let wanted = ids.filter { types?.contains($0.key) ?? true }.values.joined()
    return .linked(try samples(ids: wanted, db))
  }
}
