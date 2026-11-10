public import Foundation
import HealthCatalog
public import HealthKit
import HealthKitAccess
import IssueReporting

// What HealthKit links to a workout or an ECG, which it gives only through queries of their own
// (851-4153): the samples added to a workout (`HKQuery.predicateForObjects(from:)`), the effort
// scores related to it (`HKWorkoutEffortRelationshipQuery`), and the symptoms logged with an ECG
// (`HKQuery.predicateForObjectsAssociated(electrocardiogram:)`). Each goes up as a small record of its own,
// under the workout's or ECG's ID, rather than as fields of theirs, which a Mac only gets for
// records it already has by bootstrapping again.

/// The samples HealthKit links to a workout or an ECG, by type: each type's IDs in order of
/// start, then ID.
public struct LinkedSamples: Equatable, Sendable {
  /// The workout's or ECG's.
  public var id: UUID
  /// `nil` when there are more than ``HealthEncoder/maxLinkedSamples``: only `count` goes up.
  public var samples: [String: [UUID]]?
  public var count: Int

  public init(id: UUID, samples: [String: [UUID]]) {
    self.id = id
    self.count = samples.values.reduce(0) { $0 + $1.count }
    self.samples = count > HealthEncoder.maxLinkedSamples ? nil : samples
  }

  /// Linked samples as HealthKit gives them, grouped by type and put in order.
  public init(id: UUID, _ found: [HKSample]) {
    var samples: [String: [HKSample]] = [:]
    for sample in found { samples[sample.sampleType.identifier, default: []].append(sample) }
    self.init(
      id: id,
      samples: samples.mapValues { samples in
        Self.ordered(samples)
      })
  }

  /// Samples' IDs in the order links keep them: by start, then ID.
  static func ordered(_ samples: [HKSample]) -> [UUID] {
    samples.sorted {
      ($0.startDate, $0.uuid.uuidString) < ($1.startDate, $1.uuid.uuidString)
    }.map(\.uuid)
  }
}

/// The effort scores related to a workout (`HKWorkoutEffortRelationship`): the workout's own, and
/// each activity's of a multisport workout, with the one HealthKit finds most relevant
/// (`HKWorkoutEffortRelationshipQueryOptions.mostRelevant`).
public struct WorkoutEffortRecord: Equatable, Sendable {
  public var workout: UUID
  public var samples: [UUID]
  public var mostRelevant: UUID?
  /// Only activities with effort scores of their own, in order of start.
  public var activities: [Activity]

  public struct Activity: Equatable, Sendable {
    /// `HKWorkoutActivity.uuid`, as the workout's `activities` have it.
    public var id: UUID
    public var samples: [UUID]
    public var mostRelevant: UUID?

    public init(id: UUID, samples: [UUID], mostRelevant: UUID?) {
      self.id = id
      self.samples = samples
      self.mostRelevant = mostRelevant
    }
  }

  public init(workout: UUID, samples: [UUID], mostRelevant: UUID?, activities: [Activity]) {
    self.workout = workout
    self.samples = samples
    self.mostRelevant = mostRelevant
    self.activities = activities
  }

  /// One record per workout with effort scores, from every relationship (`relationships`) and
  /// the most relevant ones (`mostRelevant`, the same query with that option). Relationships
  /// without samples (an activity that has none, a workout whose scores were all unrelated)
  /// are left out, and so are workouts left without any.
  public static func records(
    _ relationships: [HKWorkoutEffortRelationship],
    mostRelevant: [HKWorkoutEffortRelationship]
  ) -> [WorkoutEffortRecord] {
    func key(_ relationship: HKWorkoutEffortRelationship) -> String {
      "\(relationship.workout.uuid) \(relationship.activity?.uuid.uuidString ?? "")"
    }
    let relevant = Dictionary(
      mostRelevant.map { (key($0), $0.samples?.first?.uuid) },
      uniquingKeysWith: { first, _ in first }
    )
    var byWorkout: [UUID: (workout: HKWorkout, relationships: [HKWorkoutEffortRelationship])] = [:]
    for relationship in relationships where !(relationship.samples ?? []).isEmpty {
      byWorkout[relationship.workout.uuid, default: (relationship.workout, [])]
        .relationships.append(relationship)
    }
    return byWorkout.values.map { workout, relationships in
      var record = WorkoutEffortRecord(
        workout: workout.uuid, samples: [], mostRelevant: nil, activities: [])
      var activities: [(start: Date, activity: Activity)] = []
      for relationship in relationships {
        let samples = LinkedSamples.ordered(relationship.samples ?? [])
        let mostRelevant = relevant[key(relationship)] ?? nil
        if let activity = relationship.activity {
          activities.append(
            (
              activity.startDate,
              Activity(id: activity.uuid, samples: samples, mostRelevant: mostRelevant)
            ))
        } else {
          record.samples = samples
          record.mostRelevant = mostRelevant
        }
      }
      record.activities = activities.sorted {
        ($0.start, $0.activity.id.uuidString) < ($1.start, $1.activity.id.uuidString)
      }.map(\.activity)
      return record
    }
    .sorted { $0.workout.uuidString < $1.workout.uuidString }
  }
}

extension HealthEncoder {
  public static let workoutSamplesEntity = "health_workout_samples"
  public static let workoutEffortEntity = "health_workout_effort"
  public static let electrocardiogramSymptomsEntity = "health_electrocardiogram_symptoms"

  /// The most samples linked to a workout or ECG that go up by ID: each is about 40 bytes of
  /// JSON, so a line stays under the server's 1 MB. A workout with more (a day's hike, whose
  /// energy and distance come every few seconds) goes up with its count only.
  public static let maxLinkedSamples = 20_000

  /// How the iPhone reads a workout's and an ECG's links (`HealthBackfillState`'s
  /// `dependentsEncodings`, which keeps every type's dependent records' encoding).
  /// 1: they go up (851-4153).
  public static let linksEncoding = 1

  /// The entities that go up beside a type's records, under their IDs, and aren't records of
  /// their own: a series' values, a workout's samples, an ECG's symptoms.
  public static let dependentEntities: Set<String> = [
    quantitySeriesEntity, workoutSamplesEntity, electrocardiogramSymptomsEntity,
  ]

  /// A workout's samples (`HealthWorkoutSamples` on the server).
  public static func workoutSamples(_ linked: LinkedSamples) -> HealthMutation {
    .upsert(workoutSamplesEntity, id: id(linked.id), row: linkedRow(linked))
  }

  /// An ECG's symptoms (`HealthElectrocardiogramSymptoms` on the server).
  public static func electrocardiogramSymptoms(_ linked: LinkedSamples) -> HealthMutation {
    .upsert(electrocardiogramSymptomsEntity, id: id(linked.id), row: linkedRow(linked))
  }

  private static func linkedRow(_ linked: LinkedSamples) -> [String: JSONValue] {
    [
      "count": .number(Double(linked.count)),
      "samples": linked.samples.map { samples in
        .object(samples.mapValues { .array($0.map { .string(id($0)) }) })
      } ?? .null,
    ]
  }

  /// A workout's effort scores (`HealthWorkoutEffort` on the server).
  public static func workoutEffort(_ effort: WorkoutEffortRecord) -> HealthMutation {
    func ids(_ samples: [UUID]) -> JSONValue { .array(samples.map { .string(id($0)) }) }
    return .upsert(
      workoutEffortEntity, id: id(effort.workout),
      row: [
        "samples": ids(effort.samples),
        "mostRelevant": effort.mostRelevant.map { .string(id($0)) } ?? .null,
        "legs": .array(
          effort.activities.map { activity in
            .object([
              "activity": .string(id(activity.id)),
              "samples": ids(activity.samples),
              "mostRelevant": activity.mostRelevant.map { .string(id($0)) } ?? .null,
            ])
          }),
      ])
  }
}

extension HealthReader {
  /// The types whose samples may be added to a workout: those of its statistics, which HealthKit
  /// computes from the samples added to it (and to its activities), and heart rate, which its
  /// page charts. One predicate per type: a query costs about 0.8 ms a type, so asking for
  /// every type would cost a few hundred workouts seconds each.
  static func linkedTypes(of workout: HKWorkout) -> [HKQuantityType] {
    var types = Set(workout.allStatistics.keys)
    for activity in workout.workoutActivities { types.formUnion(activity.allStatistics.keys) }
    types.insert(HKQuantityType(.heartRate))
    return types.sorted { $0.identifier < $1.identifier }
  }

  /// The symptom types an ECG's symptoms may be: every symptom the catalog has that this iOS
  /// knows (HealthKit has no type for the others).
  static let symptomTypes: [HKCategoryType] = HealthCatalog.types(
    availableOn: IOSVersion(.max)
  ).compactMap { type in
    guard type.kind == .category, type.category == .symptoms else { return nil }
    return HKObjectType.categoryType(forIdentifier: .init(rawValue: type.id))
  }

  /// The samples added to a workout, of `linkedTypes(of:)`.
  static func samples(of workout: HKWorkout, store: HKHealthStore) async throws -> LinkedSamples {
    let predicate = HKQuery.predicateForObjects(from: workout)
    return LinkedSamples(
      id: workout.uuid,
      try await linked(
        linkedTypes(of: workout).map { .sample(type: $0, predicate: predicate) }, store))
  }

  /// The symptoms logged with an ECG: none to read unless it says some were.
  static func symptoms(of ecg: HKElectrocardiogram, store: HKHealthStore) async throws
    -> LinkedSamples
  {
    guard ecg.symptomsStatus == .present else { return LinkedSamples(id: ecg.uuid, samples: [:]) }
    let predicate = HKQuery.predicateForObjectsAssociated(electrocardiogram: ecg)
    return LinkedSamples(
      id: ecg.uuid,
      try await linked(symptomTypes.map { .sample(type: $0, predicate: predicate) }, store))
  }

  /// A query of linked samples. One that fails throws `SeriesUnavailable`, as a series' does: it
  /// isn't the record's fault, so its page is read again, until the type's reads have failed
  /// `HealthBackfill.seriesAttempts` times and it's held back instead (851-4151).
  private static func linked(_ predicates: [HKSamplePredicate<HKSample>], _ store: HKHealthStore)
    async throws -> [HKSample]
  {
    do {
      return try await HKSampleQueryDescriptor(predicates: predicates, sortDescriptors: [])
        .result(for: store)
    } catch {
      let mapped = Locked.mapped(error)
      if mapped is Locked || mapped is CancellationError || Task.isCancelled { throw mapped }
      // What failed, which `SeriesUnavailable` doesn't say.
      BackfillLog.write("a query of linked samples failed: \(error)")
      throw SeriesUnavailable(expected: 0, read: 0)
    }
  }

  /// The links of a page's workouts or ECGs (``links(of:store:)``), several at once, as its
  /// series' values are read. A query that fails throws `SeriesUnavailable`, unless
  /// `skippingUnreadable`: then their owners are returned as `unreadable`, to hold back.
  static func pageLinks(
    of samples: [HKSample], skippingUnreadable: Bool, store: HKHealthStore
  ) async throws -> (links: [UUID: LinkedSamples], unreadable: Set<UUID>) {
    let owners = samples.filter { $0 is HKWorkout || $0 is HKElectrocardiogram }
    let read = try await concurrently(owners, width: HealthKitCardEngine.seriesConcurrency) {
      sample -> Result<LinkedSamples?, SeriesUnavailable> in
      do {
        return .success(try await links(of: sample, store: store))
      } catch let error as SeriesUnavailable where skippingUnreadable {
        return .failure(error)
      }
    }
    var links: [UUID: LinkedSamples] = [:]
    var unreadable: Set<UUID> = []
    for (owner, result) in zip(owners, read) {
      switch result {
      case .success(let linked): links[owner.uuid] = linked
      case .failure: unreadable.insert(owner.uuid)
      }
    }
    if !unreadable.isEmpty {
      reportIssue(
        SeriesUnavailable(expected: 0, read: 0),
        "\(unreadable.count) records' links couldn't be read")
    }
    return (links, unreadable)
  }

  /// A workout's samples or an ECG's symptoms; `nil` for anything else.
  static func links(of sample: HKSample, store: HKHealthStore) async throws -> LinkedSamples? {
    switch sample {
    case let workout as HKWorkout: try await samples(of: workout, store: store)
    case let ecg as HKElectrocardiogram: try await symptoms(of: ecg, store: store)
    default: nil
    }
  }

  /// A workout's or ECG's links as their mutation.
  static func linksMutation(_ linked: LinkedSamples, of sample: HKSample) -> HealthMutation? {
    switch sample {
    case is HKWorkout: HealthEncoder.workoutSamples(linked)
    case is HKElectrocardiogram: HealthEncoder.electrocardiogramSymptoms(linked)
    default: nil
    }
  }

  /// Only a workout or ECG type's links after `anchor`, for reading those uploaded before their
  /// links were (`HealthBackfill.readSeriesAgain`, 851-4153): the records themselves are on the
  /// server already, so an ECG's voltages aren't read. Deletions are left to the type's anchor.
  static func linksPage(
    _ type: HealthBackfillType, after anchorData: Data?, limit: Int, store: HKHealthStore
  ) async throws -> HealthPage {
    guard let sampleType = type.sampleType else { throw UnknownType(id: type.id) }
    let result = try await anchoredPage(
      sampleType, after: try unarchiveAnchor(anchorData), limit: limit, in: store)
    let (links, unreadable) = try await pageLinks(
      of: result.addedSamples, skippingUnreadable: type.skipsUnreadableSeries, store: store)
    var mutations: [HealthMutation] = []
    var failed: [String] = []
    for sample in result.addedSamples {
      if unreadable.contains(sample.uuid) {
        failed.append(HealthEncoder.id(sample.uuid))
      } else if let linked = links[sample.uuid], let mutation = linksMutation(linked, of: sample) {
        mutations.append(mutation)
      }
    }
    return HealthPage(
      mutations: mutations,
      anchor: try NSKeyedArchiver.archivedData(
        withRootObject: result.newAnchor, requiringSecureCoding: true),
      hasMore: result.addedSamples.count + result.deletedObjects.count >= limit, failed: failed)
  }
}
