import Foundation
import HealthCards
import HealthCatalog
public import SQLiteData

/// What a workout's or one of its activities' metadata says of it, by HealthKit's keys, read as
/// the server's Health tools read it (`Services/api/src/health/tools/Workouts.ts`), so the two
/// `workouts` tools agree (the conformance cases, 851-4015).
public struct WorkoutMetadata: Equatable, Sendable {
  /// `HKMetadataKeyIndoorWorkout`: a Boolean, or 0 or 1 from apps that write it as a number.
  public var indoor: Bool?
  /// `HKMetadataKeySwimmingLocationType`: `pool` (1) or `openWater` (2).
  public var swimmingLocation: String?
  /// `HKMetadataKeyWorkoutBrandName`, unless it's blank. Apple's Workout app doesn't name
  /// workouts.
  public var brandName: String?
  /// `HKMetadataKeyElevationAscended`, in meters.
  public var elevationAscended: Double?
  /// The name of the WorkoutKit plan it was recorded from, unless it's blank: the iPhone keeps
  /// the plan under its own key (`LilWorkoutPlan`, 851-4030), as `{ kind, name, activityType,
  /// locationType }`. Custom and swim-bike-run workouts have one.
  public var planName: String?

  // What the `workout` tool reads besides (851-4165), on workouts, activities and events, as the
  // server reads them (`Services/api/src/health/tools/WorkoutValues.ts`). Every key is read as
  // `HealthMetadataValues` reads it (851-4170).

  /// `HKMetadataKeyElevationDescended`, in meters.
  public var elevationDescended: Double?
  /// `HKMetadataKeyAverageSpeed`, in meters per second.
  public var averageSpeed: Double?
  /// `HKMetadataKeyMaximumSpeed`, in meters per second.
  public var maximumSpeed: Double?
  /// `HKMetadataKeyAverageMETs`, in METs (kcal/hr·kg).
  public var averageMETs: Double?
  /// `HKMetadataKeyLapLength`, a pool's length, in meters.
  public var lapLength: Double?
  /// `HKMetadataKeySWOLFScore`.
  public var swolf: Double?
  /// `HKMetadataKeyWeatherCondition`, as `HKWeatherCondition` names it (`clear`, `showers`…).
  public var weatherCondition: String?
  /// `HKMetadataKeyWeatherTemperature`, in degrees Celsius.
  public var weatherTemperature: Double?
  /// `HKMetadataKeyWeatherHumidity`, a percent from 0 to 100 (see
  /// `HealthMetadataValues.Quantity.humidity`).
  public var weatherHumidity: Double?
  /// `HKMetadataKeySwimmingStrokeStyle`, as `HKSwimmingStrokeStyle` names it (`freestyle`…), on
  /// laps and segments.
  public var strokeStyle: String?
  /// `HKTimeZone`, the zone it was recorded in, as text: the tools take it when it's a name
  /// (`RecordedZones`, 851-4177).
  public var timeZoneName: String?

  public init(
    indoor: Bool? = nil, swimmingLocation: String? = nil, brandName: String? = nil,
    elevationAscended: Double? = nil, planName: String? = nil, elevationDescended: Double? = nil,
    averageSpeed: Double? = nil, maximumSpeed: Double? = nil, averageMETs: Double? = nil,
    lapLength: Double? = nil, swolf: Double? = nil, weatherCondition: String? = nil,
    weatherTemperature: Double? = nil, weatherHumidity: Double? = nil, strokeStyle: String? = nil,
    timeZoneName: String? = nil
  ) {
    self.indoor = indoor
    self.swimmingLocation = swimmingLocation
    self.brandName = brandName
    self.elevationAscended = elevationAscended
    self.planName = planName
    self.elevationDescended = elevationDescended
    self.averageSpeed = averageSpeed
    self.maximumSpeed = maximumSpeed
    self.averageMETs = averageMETs
    self.lapLength = lapLength
    self.swolf = swolf
    self.weatherCondition = weatherCondition
    self.weatherTemperature = weatherTemperature
    self.weatherHumidity = weatherHumidity
    self.strokeStyle = strokeStyle
    self.timeZoneName = timeZoneName
  }

  /// Its name: the app's (`brandName`), else its plan's.
  public var name: String? { brandName ?? planName }

  /// From metadata as the iPhone encodes it (`HealthEncoder.json`), or nothing if it isn't an
  /// object.
  init(_ metadata: Any?) {
    guard let metadata = metadata as? [String: Any] else {
      self.init()
      return
    }
    func value(_ key: String) -> HealthMetadataValues.Value? {
      HealthMetadataValues.value(key, in: metadata)
    }
    self.init(
      indoor: value("HKIndoorWorkout")?.bool,
      swimmingLocation: value("HKSwimmingLocationType")?.string,
      brandName: value("HKWorkoutBrandName")?.string,
      elevationAscended: value("HKElevationAscended")?.double,
      planName: HealthMetadataValues.text((metadata["LilWorkoutPlan"] as? [String: Any])?["name"]),
      elevationDescended: value("HKElevationDescended")?.double,
      averageSpeed: value("HKAverageSpeed")?.double,
      maximumSpeed: value("HKMaximumSpeed")?.double,
      averageMETs: value("HKAverageMETs")?.double,
      lapLength: value("HKLapLength")?.double,
      swolf: value("HKSWOLFScore")?.double,
      weatherCondition: value("HKWeatherCondition")?.string,
      weatherTemperature: value("HKWeatherTemperature")?.double,
      weatherHumidity: value("HKWeatherHumidity")?.double,
      strokeStyle: value("HKSwimmingStrokeStyle")?.string,
      timeZoneName: value("HKTimeZone")?.string)
  }

  /// Indoors or not, by an `HKWorkoutSessionLocationType` raw value: 2 indoor, 3 outdoor, and
  /// nil for 1 (unknown) or anything else.
  static func indoor(locationType: Double?) -> Bool? {
    CardWorkout.indoor(locationType: locationType)
  }

  /// `pool` or `openWater`, by an `HKWorkoutSwimmingLocationType` raw value, as the metadata's
  /// `HKSwimmingLocationType` and a configuration's have it: 1 pool, 2 open water, and nil for 0
  /// (unknown) or anything else.
  static func swimmingLocation(_ type: Double?) -> String? {
    HealthMetadataValues.named(HealthMetadataValues.swimmingLocations, type)
  }

  /// A JSON number that's an integer, as the server's `Schema.Int` takes it (a safe one).
  static func integer(_ value: Any?) -> Int? {
    guard let number = HealthMetadataValues.number(value), number.rounded() == number,
      number.magnitude <= 9_007_199_254_740_991
    else { return nil }
    return Int(number)
  }
}

/// One of a workout's events (`HKWorkoutEvent`), with what its metadata says: a lap's stroke
/// and SWOLF, for one.
public struct WorkoutEventRecord: Equatable, Sendable {
  public var event: WorkoutEvent
  public var metadata: WorkoutMetadata

  public init(event: WorkoutEvent, metadata: WorkoutMetadata) {
    self.event = event
    self.metadata = metadata
  }
}

/// One of a workout's activities (`HKWorkoutActivity`), the legs of a multisport workout.
public struct WorkoutActivityRecord: Equatable, Sendable {
  /// `HKWorkoutActivityType`'s raw value.
  public var activityType: Int
  public var startDate: Double
  /// `nil` while it was still going.
  public var endDate: Double?
  /// Seconds of activity, excluding pauses.
  public var duration: Double
  /// Its configuration's `HKWorkoutSessionLocationType` raw value (1 unknown, 2 indoor,
  /// 3 outdoor), from iPhones since 851-4030; nil before.
  public var locationType: Double?
  /// Its configuration's `HKWorkoutSwimmingLocationType` raw value (0 unknown, 1 pool, 2 open
  /// water), from iPhones since 851-4030; nil before.
  public var swimmingLocationType: Double?
  public var metadata: WorkoutMetadata
  /// Its own statistics, by type ID, read on their own (851-4165): ones that can't be read
  /// leave it none, as on the server.
  public var statistics: [String: WorkoutStatistic]

  public init(
    activityType: Int, startDate: Double, endDate: Double?, duration: Double,
    locationType: Double? = nil, swimmingLocationType: Double? = nil, metadata: WorkoutMetadata,
    statistics: [String: WorkoutStatistic] = [:]
  ) {
    self.activityType = activityType
    self.startDate = startDate
    self.endDate = endDate
    self.duration = duration
    self.locationType = locationType
    self.swimmingLocationType = swimmingLocationType
    self.metadata = metadata
    self.statistics = statistics
  }

  /// Whether it was indoors: as its metadata says, else as its configuration does.
  public var indoor: Bool? {
    metadata.indoor ?? WorkoutMetadata.indoor(locationType: locationType)
  }

  /// `pool` or `openWater`: as its metadata says, else as its configuration does.
  public var swimmingLocation: String? {
    metadata.swimmingLocation ?? WorkoutMetadata.swimmingLocation(swimmingLocationType)
  }
}

extension HealthWorkout {
  /// What its metadata says (``WorkoutMetadata``).
  public var decodedMetadata: WorkoutMetadata { Self.decodedMetadata(metadata) }

  /// Its activities, often none (`HealthWorkout` on the server). Read like its statistics: all
  /// of them or, if one can't be read, none.
  public var decodedActivities: [WorkoutActivityRecord] { Self.decodedActivities(activities) }

  /// Whether a workout was indoors, from its `metadata` and `activities` columns, as the
  /// `workouts` tools say (`location(metadata:activities:)`): what cards' workout windows keep
  /// by (851-4031).
  static func indoor(metadata: String?, activities: String) -> Bool? {
    location(metadata: decodedMetadata(metadata), activities: decodedActivities(activities))
      .indoor
  }

  static func decodedMetadata(_ metadata: String?) -> WorkoutMetadata {
    WorkoutMetadata(
      metadata.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) })
  }

  static func decodedActivities(_ activities: String) -> [WorkoutActivityRecord] {
    guard
      let array = (try? JSONSerialization.jsonObject(with: Data(activities.utf8))) as? [Any]
    else { return [] }
    var records: [WorkoutActivityRecord] = []
    for element in array {
      guard let object = element as? [String: Any],
        let activityType = WorkoutMetadata.integer(object["activityType"]),
        let startDate = HealthMetadataValues.number(object["startDate"]),
        let duration = HealthMetadataValues.number(object["duration"])
      else { return [] }
      let endDate: Double?
      switch object["endDate"] {
      case is NSNull: endDate = nil
      case let value:
        guard let value = HealthMetadataValues.number(value) else { return [] }
        endDate = value
      }
      // Missing or null, or a number: `.some(nil)` for none, `nil` for anything else.
      func optionalNumber(_ key: String) -> Double?? {
        switch object[key] {
        case nil, is NSNull: .some(nil)
        case let value: HealthMetadataValues.number(value).map(Optional.some)
        }
      }
      guard let locationType = optionalNumber("locationType"),
        let swimmingLocationType = optionalNumber("swimmingLocationType")
      else { return [] }
      let metadata = object["metadata"]
      if let metadata, !(metadata is NSNull), !(metadata is [String: Any]) { return [] }
      records.append(
        WorkoutActivityRecord(
          activityType: activityType, startDate: startDate, endDate: endDate,
          duration: duration, locationType: locationType,
          swimmingLocationType: swimmingLocationType,
          metadata: WorkoutMetadata(metadata),
          statistics: WorkoutStatistic.statistics(object["statistics"]) ?? [:]))
    }
    return records
  }

  /// Its events, with what their metadata says (the `workout` tool's laps and segments): all
  /// of them, in the order HealthKit gave them, or, if one can't be read, none. A `metadata`
  /// that isn't an object is taken for none, as on the server.
  public var decodedEventRecords: [WorkoutEventRecord] {
    guard let array = (try? JSONSerialization.jsonObject(with: Data(events.utf8))) as? [Any]
    else { return [] }
    var records: [WorkoutEventRecord] = []
    for element in array {
      guard let object = element as? [String: Any],
        let type = WorkoutMetadata.integer(object["type"]),
        let startDate = WorkoutMetadata.integer(object["startDate"]),
        let endDate = WorkoutMetadata.integer(object["endDate"])
      else { return [] }
      records.append(
        WorkoutEventRecord(
          event: WorkoutEvent(type: type, startDate: startDate, endDate: endDate),
          metadata: WorkoutMetadata(object["metadata"])))
    }
    return records
  }

  /// Where it was, indoors or not, and in a pool or open water: as its `metadata` says or, if it
  /// doesn't, as its `activities` say (their metadata, else their configurations), if they
  /// agree. A workout of one activity may only say on its activity, and a multisport workout's
  /// transitions don't say.
  public static func location(metadata: WorkoutMetadata, activities: [WorkoutActivityRecord])
    -> (indoor: Bool?, swimmingLocation: String?)
  {
    (
      CardWorkout.indoor(workout: metadata.indoor, activities: activities.map(\.indoor)),
      metadata.swimmingLocation ?? agreed(activities.map(\.swimmingLocation))
    )
  }

  /// The value of those that have one, if they agree; else nil.
  static func agreed<Value: Equatable>(_ values: [Value?]) -> Value? {
    let given = values.compactMap(\.self)
    guard let first = given.first, given.allSatisfy({ $0 == first }) else { return nil }
    return first
  }
}

extension HealthDatabase {
  /// The IDs of those of `workouts` that have a route with locations, as ``route(of:_:)`` finds
  /// one: linked to the workout or, failing that, linked to none and recorded during it. One read
  /// of the routes for all of them, rather than a search of the routes for each.
  public static func workoutsWithRoutes(_ workouts: [HealthWorkout], _ db: Database) throws
    -> Set<String>
  {
    guard let from = workouts.map(\.startDate).min(), let to = workouts.map(\.endDate).max()
    else { return [] }
    let ids = workouts.map(\.id)
    let routes: [(String?, Int, Int)] =
      try HealthWorkoutRoute
      .where {
        $0.locations.isNot(nil)
          && ($0.workout.in(ids.map(Optional.some))
            || ($0.workout.is(nil) && $0.startDate < to && $0.endDate > from))
      }
      .select { ($0.workout, $0.startDate, $0.endDate) }
      .fetchAll(db)
    return Set(
      workouts.filter { workout in
        routes.contains { linked, start, end in
          linked.map { $0 == workout.id } ?? (start < workout.endDate && end > workout.startDate)
        }
      }
      .map(\.id))
  }
}
