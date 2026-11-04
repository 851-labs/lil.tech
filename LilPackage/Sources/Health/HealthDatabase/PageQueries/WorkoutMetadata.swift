import Foundation
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

  public init(
    indoor: Bool? = nil, swimmingLocation: String? = nil, brandName: String? = nil,
    elevationAscended: Double? = nil, planName: String? = nil
  ) {
    self.indoor = indoor
    self.swimmingLocation = swimmingLocation
    self.brandName = brandName
    self.elevationAscended = elevationAscended
    self.planName = planName
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
    let indoor = metadata["HKIndoorWorkout"]
    self.init(
      indoor: Self.isBoolean(indoor)
        ? (indoor as? Bool)
        : Self.number(indoor).flatMap { $0 == 1 ? true : $0 == 0 ? false : nil },
      swimmingLocation: Self.swimmingLocation(Self.number(metadata["HKSwimmingLocationType"])),
      brandName: Self.unlessBlank(metadata["HKWorkoutBrandName"]),
      elevationAscended: Self.meters(metadata["HKElevationAscended"] as? String),
      planName: Self.unlessBlank((metadata["LilWorkoutPlan"] as? [String: Any])?["name"]))
  }

  /// A string unless it's blank: only spaces, tabs and line breaks, as on the server.
  static func unlessBlank(_ value: Any?) -> String? {
    (value as? String).flatMap {
      $0.unicodeScalars.allSatisfy { " \t\n\r".unicodeScalars.contains($0) } ? nil : $0
    }
  }

  /// Indoors or not, by an `HKWorkoutSessionLocationType` raw value: 2 indoor, 3 outdoor, and
  /// nil for 1 (unknown) or anything else.
  static func indoor(locationType: Double?) -> Bool? {
    locationType == 2 ? true : locationType == 3 ? false : nil
  }

  /// `pool` or `openWater`, by an `HKWorkoutSwimmingLocationType` raw value, as the metadata's
  /// `HKSwimmingLocationType` and a configuration's have it: 1 pool, 2 open water, and nil for 0
  /// (unknown) or anything else.
  static func swimmingLocation(_ type: Double?) -> String? {
    type == 1 ? "pool" : type == 2 ? "openWater" : nil
  }

  /// Meters in each length unit HealthKit writes a quantity in (`HKUnit`'s unit strings).
  static let meters: [String: Double] = [
    "mm": 0.001, "cm": 0.01, "m": 1, "km": 1000, "in": 0.0254, "ft": 0.3048, "yd": 0.9144,
    "mi": 1609.344,
  ]

  /// A length the iPhone wrote as its quantity's description, a number and a unit ("4250 cm"),
  /// in meters, or nil for anything else or another unit.
  static func meters(_ description: String?) -> Double? {
    guard let description,
      let match = description.wholeMatch(
        of: /([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?) (\S+)/),
      let number = Double(match.1), let factor = meters[String(match.2)]
    else { return nil }
    let length = number * factor
    return length.isFinite ? length : nil
  }

  static func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  /// A JSON number, not a Boolean.
  static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite
    else { return nil }
    return number.doubleValue
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

  public init(
    activityType: Int, startDate: Double, endDate: Double?, duration: Double,
    locationType: Double? = nil, swimmingLocationType: Double? = nil, metadata: WorkoutMetadata
  ) {
    self.activityType = activityType
    self.startDate = startDate
    self.endDate = endDate
    self.duration = duration
    self.locationType = locationType
    self.swimmingLocationType = swimmingLocationType
    self.metadata = metadata
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
        let activityType = WorkoutMetadata.number(object["activityType"]),
        // An integer, as the server's `Schema.Int` takes it (a safe one).
        activityType.rounded() == activityType, activityType.magnitude <= 9_007_199_254_740_991,
        let startDate = WorkoutMetadata.number(object["startDate"]),
        let duration = WorkoutMetadata.number(object["duration"])
      else { return [] }
      let endDate: Double?
      switch object["endDate"] {
      case is NSNull: endDate = nil
      case let value:
        guard let value = WorkoutMetadata.number(value) else { return [] }
        endDate = value
      }
      // Missing or null, or a number: `.some(nil)` for none, `nil` for anything else.
      func optionalNumber(_ key: String) -> Double?? {
        switch object[key] {
        case nil, is NSNull: .some(nil)
        case let value: WorkoutMetadata.number(value).map(Optional.some)
        }
      }
      guard let locationType = optionalNumber("locationType"),
        let swimmingLocationType = optionalNumber("swimmingLocationType")
      else { return [] }
      let metadata = object["metadata"]
      if let metadata, !(metadata is NSNull), !(metadata is [String: Any]) { return [] }
      records.append(
        WorkoutActivityRecord(
          activityType: Int(activityType), startDate: startDate, endDate: endDate,
          duration: duration, locationType: locationType,
          swimmingLocationType: swimmingLocationType,
          metadata: WorkoutMetadata(metadata)))
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
      metadata.indoor ?? agreed(activities.map(\.indoor)),
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
