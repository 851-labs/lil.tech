import Foundation
public import GRDB
import SQLiteData

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

/// A workout's heart rate, as its page charts it, and how it was found (851-4186).
public struct WorkoutHeartRates: Equatable, Sendable {
  public enum Origin: Equatable, Sendable {
    /// The readings its app added to it, as its link record says (851-4153).
    case linked
    /// The main source's readings during it (``HealthDatabase/mainSource(_:)``), since its link
    /// record hasn't synced (``LinkedSamples/notSynced``).
    case notSynced
    /// The same guess, since it linked more samples than the iPhone uploads
    /// (``LinkedSamples/tooMany(count:)``).
    case tooMany
  }

  public var samples: [HealthSample]
  public var origin: Origin

  public init(samples: [HealthSample] = [], origin: Origin = .linked) {
    self.samples = samples
    self.origin = origin
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

  /// The tables a workout's links are read from, for pages that follow sync (`ThrottledFetch`):
  /// its records and the samples they name, which may arrive after them.
  public static let workoutLinkTables: [any DatabaseRegionConvertible] = [
    HealthSample.tableName, HealthWorkoutSamples.tableName, HealthWorkoutEffort.tableName,
  ].map { GRDB.Table<Row>($0) }

  /// The tables an ECG's symptoms are read from, as ``workoutLinkTables`` are a workout's.
  public static let electrocardiogramLinkTables: [any DatabaseRegionConvertible] = [
    HealthSample.tableName, HealthElectrocardiogramSymptoms.tableName,
  ].map { GRDB.Table<Row>($0) }

  /// The workout's heart rate: the readings linked to it, or, until its links sync (or if there
  /// were too many to upload), the readings during it of the source with the most. Either way only
  /// one source's (``mainSource(_:)``), so a second device's readings don't zig-zag through a
  /// chart.
  public static func workoutHeartRates(of workout: HealthWorkout, _ db: Database) throws
    -> WorkoutHeartRates
  {
    let origin: WorkoutHeartRates.Origin
    switch try linkedSamples(ofWorkout: workout.id, types: [heartRateType], db) {
    case .linked(let samples):
      return WorkoutHeartRates(samples: mainSource(samples), origin: .linked)
    case .notSynced: origin = .notSynced
    case .tooMany: origin = .tooMany
    }
    let during = try samples(
      of: heartRateType,
      in: Date(unixMilliseconds: workout.startDate)..<Date(unixMilliseconds: workout.endDate), db)
    return WorkoutHeartRates(samples: mainSource(during), origin: origin)
  }

  /// The samples of the source that recorded the most of them (usually the Watch), ties to the
  /// first by bundle ID.
  public static func mainSource(_ samples: [HealthSample]) -> [HealthSample] {
    let counts = Dictionary(grouping: samples, by: \.sourceBundleID).mapValues(\.count)
    guard let source = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key
    else { return [] }
    return samples.filter { $0.sourceBundleID == source }
  }

  /// The samples of `types` (all of them if nil) its app added to the workout with ID
  /// `workoutID`, as its `healthWorkoutSamples` record links them.
  public static func linkedSamples(
    ofWorkout workoutID: String, types: Set<String>? = nil, _ db: Database
  ) throws -> LinkedSamples {
    guard let record = try HealthWorkoutSamples.find(workoutID).fetchOne(db) else {
      return .notSynced
    }
    return try linkedSamples(record.samples, count: record.count, types: types, db)
  }

  /// The symptoms logged with the ECG with ID `electrocardiogramID`, as its
  /// `healthElectrocardiogramSymptoms` record links them.
  public static func symptoms(
    ofElectrocardiogram electrocardiogramID: String, _ db: Database
  ) throws -> LinkedSamples {
    guard let record = try HealthElectrocardiogramSymptoms.find(electrocardiogramID).fetchOne(db)
    else { return .notSynced }
    return try linkedSamples(record.samples, count: record.count, types: nil, db)
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
  /// finds most relevant, else (it hasn't arrived) the latest the person rated that has, else
  /// Apple Watch's latest estimate.
  public static func effortScore(
    _ ids: [String], mostRelevant: String?, _ db: Database
  ) throws -> HealthSample? {
    let samples = try samples(ids: ids, db)
    return samples.first { $0.id == mostRelevant }
      ?? samples.last { $0.type == workoutEffortScoreType } ?? samples.last
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

  /// A record's samples: none uploaded is too many, and JSON that can't be read is taken for a
  /// record not synced, so readers fall back to what they did before rather than show nothing.
  private static func linkedSamples(
    _ json: String?, count: Int, types: Set<String>?, _ db: Database
  ) throws -> LinkedSamples {
    guard let json else { return .tooMany(count: count) }
    guard let ids = linkedIDs(json) else { return .notSynced }
    let wanted = ids.filter { types?.contains($0.key) ?? true }.values.joined()
    return .linked(try samples(ids: wanted, db))
  }
}
