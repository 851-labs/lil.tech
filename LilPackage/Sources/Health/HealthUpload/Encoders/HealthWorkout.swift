public import Foundation
import HealthCatalog
public import HealthKit
import IssueReporting
public import WorkoutKit

/// A workout's contents, read out of `HKWorkout` (`init(_:)`) so the encoding can be tested
/// without HealthKit, whose workout initializers are deprecated.
public struct WorkoutRecord: Equatable, Sendable {
  public var id: UUID
  /// `HKWorkoutActivityType`'s raw value.
  public var activityType: UInt
  /// Seconds of activity, excluding pauses.
  public var duration: TimeInterval
  public var activities: [Activity]
  public var events: [Event]
  public var statistics: [Statistic]
  /// Times, source, device and metadata (`HealthEncoder.provenance(of:)`).
  public var provenance: [String: JSONValue]
  /// The WorkoutKit plan it was recorded from (a custom, pacer, goal or swim-bike-run workout),
  /// if any.
  public var plan: Plan?

  public struct Activity: Equatable, Sendable {
    public var id: UUID
    public var activityType: UInt
    public var startDate: Date
    /// `nil` while the activity is still going.
    public var endDate: Date?
    public var duration: TimeInterval
    /// Its configuration's `HKWorkoutSessionLocationType` raw value: 1 unknown, 2 indoor,
    /// 3 outdoor.
    public var locationType: Int
    /// Its configuration's `HKWorkoutSwimmingLocationType` raw value: 0 unknown, 1 pool,
    /// 2 open water.
    public var swimmingLocationType: Int
    public var metadata: [String: JSONValue]?
    public var statistics: [Statistic]

    public init(
      id: UUID, activityType: UInt, startDate: Date, endDate: Date?, duration: TimeInterval,
      locationType: Int = HKWorkoutSessionLocationType.unknown.rawValue,
      swimmingLocationType: Int = HKWorkoutSwimmingLocationType.unknown.rawValue,
      metadata: [String: JSONValue]?, statistics: [Statistic]
    ) {
      self.id = id
      self.activityType = activityType
      self.startDate = startDate
      self.endDate = endDate
      self.duration = duration
      self.locationType = locationType
      self.swimmingLocationType = swimmingLocationType
      self.metadata = metadata
      self.statistics = statistics
    }
  }

  /// A WorkoutKit plan (`HKWorkout.workoutPlan`): what was planned, as the Workout app on the
  /// Watch ran it.
  public struct Plan: Equatable, Sendable {
    /// `goal`, `custom`, `pacer` or `swimBikeRun`, or `unknown` for a kind WorkoutKit adds later
    /// (whose name, if it has one, isn't read).
    public var kind: String
    /// The name the plan was given: custom and swim-bike-run workouts have one, if their app
    /// named them.
    public var name: String?
    /// `HKWorkoutActivityType`'s raw value; `swimBikeRun` for a swim-bike-run.
    public var activityType: UInt
    /// `HKWorkoutSessionLocationType`'s raw value, or nil for a swim-bike-run, whose legs each
    /// have one.
    public var locationType: Int?

    public init(kind: String, name: String?, activityType: UInt, locationType: Int?) {
      self.kind = kind
      self.name = name
      self.activityType = activityType
      self.locationType = locationType
    }

    public init(_ plan: WorkoutPlan) {
      let activityType = plan.workout.activity.rawValue
      switch plan.workout {
      case .goal(let workout):
        self.init(
          kind: "goal", name: nil, activityType: activityType,
          locationType: workout.location.rawValue)
      case .custom(let workout):
        self.init(
          kind: "custom", name: workout.displayName, activityType: activityType,
          locationType: workout.location.rawValue)
      case .pacer(let workout):
        self.init(
          kind: "pacer", name: nil, activityType: activityType,
          locationType: workout.location.rawValue)
      case .swimBikeRun(let workout):
        self.init(
          kind: "swimBikeRun", name: workout.displayName, activityType: activityType,
          locationType: nil)
      @unknown default:
        self.init(kind: "unknown", name: nil, activityType: activityType, locationType: nil)
      }
    }
  }

  public struct Event: Equatable, Sendable {
    /// `HKWorkoutEventType`'s raw value, e.g. 1 for a pause.
    public var type: Int
    public var startDate: Date
    public var endDate: Date
    public var metadata: [String: JSONValue]?

    public init(type: Int, startDate: Date, endDate: Date, metadata: [String: JSONValue]?) {
      self.type = type
      self.startDate = startDate
      self.endDate = endDate
      self.metadata = metadata
    }
  }

  /// One quantity type's statistics over the workout or an activity, in the catalog's unit.
  public struct Statistic: Equatable, Sendable {
    public var type: String
    public var unit: String
    public var sum: Double?
    public var average: Double?
    public var minimum: Double?
    public var maximum: Double?
    public var mostRecent: Double?

    public init(
      type: String, unit: String, sum: Double? = nil, average: Double? = nil,
      minimum: Double? = nil, maximum: Double? = nil, mostRecent: Double? = nil
    ) {
      self.type = type
      self.unit = unit
      self.sum = sum
      self.average = average
      self.minimum = minimum
      self.maximum = maximum
      self.mostRecent = mostRecent
    }
  }

  public init(
    id: UUID, activityType: UInt, duration: TimeInterval, activities: [Activity],
    events: [Event], statistics: [Statistic], provenance: [String: JSONValue], plan: Plan? = nil
  ) {
    self.id = id
    self.activityType = activityType
    self.duration = duration
    self.activities = activities
    self.events = events
    self.statistics = statistics
    self.provenance = provenance
    self.plan = plan
  }
}

extension WorkoutRecord {
  /// Reads a workout out of HealthKit, with its WorkoutKit plan. Statistics for types the
  /// catalog has no unit for are left out.
  public init(_ workout: HKWorkout) async throws {
    self.init(workout, plan: try await Self.plan(of: workout))
  }

  /// Reads a workout out of HealthKit, with the plan given.
  init(_ workout: HKWorkout, plan: Plan?) {
    self.init(
      id: workout.uuid,
      activityType: workout.workoutActivityType.rawValue,
      duration: workout.duration,
      activities: workout.workoutActivities.map { activity in
        Activity(
          id: activity.uuid,
          activityType: activity.workoutConfiguration.activityType.rawValue,
          startDate: activity.startDate,
          endDate: activity.endDate,
          duration: activity.duration,
          locationType: activity.workoutConfiguration.locationType.rawValue,
          swimmingLocationType: activity.workoutConfiguration.swimmingLocationType.rawValue,
          metadata: activity.metadata.map { $0.mapValues(HealthEncoder.json) },
          statistics: Self.statistics(activity.allStatistics))
      },
      events: (workout.workoutEvents ?? []).map { event in
        Event(
          type: event.type.rawValue, startDate: event.dateInterval.start,
          endDate: event.dateInterval.end,
          metadata: event.metadata.map { $0.mapValues(HealthEncoder.json) })
      },
      statistics: Self.statistics(workout.allStatistics),
      provenance: HealthEncoder.provenance(of: workout), plan: plan)
  }

  /// The workout's WorkoutKit plan, if it has one. A workout without one doesn't give nil:
  /// `workoutPlan` throws WorkoutKit's `ImportError` (code 3 on iOS 27.2, for a workout an app
  /// recorded; `unsupportedPlatform` on macOS), which isn't public, so it's known by its domain.
  /// Any other failure is reported and leaves the plan out, rather than keeping the workout from
  /// going up, unless HealthKit is locked (the page is read again once it isn't).
  static func plan(of workout: HKWorkout) async throws -> Plan? {
    do {
      return try await workout.workoutPlan.map(Plan.init)
    } catch {
      let mapped = HealthReader.Locked.mapped(error)
      if mapped is HealthReader.Locked || mapped is CancellationError { throw mapped }
      if (error as NSError).domain != noPlanErrorDomain {
        reportIssue(error, "Reading a workout's plan")
      }
      return nil
    }
  }

  /// The domain of the error `HKWorkout.workoutPlan` throws for a workout without a plan.
  static let noPlanErrorDomain = "WorkoutKit.ImportError"

  private static func statistics(_ all: [HKQuantityType: HKStatistics]) -> [Statistic] {
    all.compactMap { type, statistics in
      guard let unitString = HealthCatalog.type(id: type.identifier)?.unit else { return nil }
      let unit = HKUnit(from: unitString)
      let value = { (quantity: HKQuantity?) in
        quantity.flatMap { $0.is(compatibleWith: unit) ? $0.doubleValue(for: unit) : nil }
      }
      return Statistic(
        type: type.identifier, unit: unitString, sum: value(statistics.sumQuantity()),
        average: value(statistics.averageQuantity()),
        minimum: value(statistics.minimumQuantity()),
        maximum: value(statistics.maximumQuantity()),
        mostRecent: value(statistics.mostRecentQuantity()))
    }
    .sorted { $0.type < $1.type }
  }
}

extension HealthEncoder {
  public static let workoutEntity = "health_workout"

  /// The key of a workout's WorkoutKit plan in its `metadata` (851-4030), beside HealthKit's own
  /// keys: `{ kind, name, activityType, locationType }`, absent when it has none. In the metadata
  /// rather than a field of its own, which every Mac would bootstrap its whole copy again to get
  /// (`docs/sync/protocol.md` › Schema changes), since every client keeps the metadata whole.
  public static let workoutPlanKey = "LilWorkoutPlan"

  /// What's in a workout's upload. Bump it when the iPhone starts uploading something new of
  /// workouts, so the ones already uploaded are read and go up again (`HealthBackfillState`'s
  /// `workoutEncoding`). 1: their activities' locations and their plans (851-4030).
  public static let workoutEncoding = 1

  /// A workout, with its activities, events and statistics as JSON.
  public static func workout(_ workout: WorkoutRecord) -> HealthMutation {
    var row = workout.provenance
    if let plan = workout.plan {
      var metadata: [String: JSONValue] = [:]
      if case .object(let recorded) = row["metadata"] { metadata = recorded }
      metadata[workoutPlanKey] = .object([
        "kind": .string(plan.kind), "name": plan.name.map(JSONValue.string) ?? .null,
        "activityType": .number(Double(plan.activityType)),
        "locationType": plan.locationType.map { .number(Double($0)) } ?? .null,
      ])
      row["metadata"] = .object(metadata)
    }
    row["activityType"] = .number(Double(workout.activityType))
    row["duration"] = .number(workout.duration)
    row["activities"] = .array(
      workout.activities.map { activity in
        .object([
          "id": .string(id(activity.id)),
          "activityType": .number(Double(activity.activityType)),
          "startDate": .number(milliseconds(activity.startDate)),
          "endDate": activity.endDate.map { .number(milliseconds($0)) } ?? .null,
          "duration": .number(activity.duration),
          "locationType": .number(Double(activity.locationType)),
          "swimmingLocationType": .number(Double(activity.swimmingLocationType)),
          "metadata": activity.metadata.map(JSONValue.object) ?? .null,
          "statistics": statistics(activity.statistics),
        ])
      })
    row["events"] = .array(
      workout.events.map { event in
        .object([
          "type": .number(Double(event.type)),
          "startDate": .number(milliseconds(event.startDate)),
          "endDate": .number(milliseconds(event.endDate)),
          "metadata": event.metadata.map(JSONValue.object) ?? .null,
        ])
      })
    row["statistics"] = statistics(workout.statistics)
    return .upsert(workoutEntity, id: id(workout.id), row: row)
  }

  private static func statistics(_ statistics: [WorkoutRecord.Statistic]) -> JSONValue {
    .object(
      Dictionary(
        uniqueKeysWithValues: statistics.map { statistic in
          (
            statistic.type,
            JSONValue.object([
              "unit": .string(statistic.unit), "sum": JSONValue(statistic.sum),
              "average": JSONValue(statistic.average), "minimum": JSONValue(statistic.minimum),
              "maximum": JSONValue(statistic.maximum),
              "mostRecent": JSONValue(statistic.mostRecent),
            ])
          )
        }))
  }
}
