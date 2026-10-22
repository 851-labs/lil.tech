public import Foundation
import HealthCatalog
public import HealthKit

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

  public struct Activity: Equatable, Sendable {
    public var id: UUID
    public var activityType: UInt
    public var startDate: Date
    /// `nil` while the activity is still going.
    public var endDate: Date?
    public var duration: TimeInterval
    public var metadata: [String: JSONValue]?
    public var statistics: [Statistic]

    public init(
      id: UUID, activityType: UInt, startDate: Date, endDate: Date?, duration: TimeInterval,
      metadata: [String: JSONValue]?, statistics: [Statistic]
    ) {
      self.id = id
      self.activityType = activityType
      self.startDate = startDate
      self.endDate = endDate
      self.duration = duration
      self.metadata = metadata
      self.statistics = statistics
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
    events: [Event], statistics: [Statistic], provenance: [String: JSONValue]
  ) {
    self.id = id
    self.activityType = activityType
    self.duration = duration
    self.activities = activities
    self.events = events
    self.statistics = statistics
    self.provenance = provenance
  }
}

extension WorkoutRecord {
  /// Reads a workout out of HealthKit. Statistics for types the catalog has no unit for are
  /// left out.
  public init(_ workout: HKWorkout) {
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
      provenance: HealthEncoder.provenance(of: workout))
  }

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

  /// A workout, with its activities, events and statistics as JSON.
  public static func workout(_ workout: WorkoutRecord) -> HealthMutation {
    var row = workout.provenance
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
