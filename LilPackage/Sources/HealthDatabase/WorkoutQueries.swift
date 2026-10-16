public import Foundation
public import SQLiteData

/// One quantity type's statistics over a workout, in the catalog's unit.
public struct WorkoutStatistic: Codable, Equatable, Sendable {
  public var unit: String
  public var sum: Double?
  public var average: Double?
  public var minimum: Double?
  public var maximum: Double?

  public init(
    unit: String, sum: Double? = nil, average: Double? = nil, minimum: Double? = nil,
    maximum: Double? = nil
  ) {
    self.unit = unit
    self.sum = sum
    self.average = average
    self.minimum = minimum
    self.maximum = maximum
  }
}

/// A workout event (`HKWorkoutEvent`): a pause, a lap, a segment…
public struct WorkoutEvent: Codable, Equatable, Sendable {
  /// `HKWorkoutEventType`'s raw value.
  public var type: Int
  public var startDate: Int
  public var endDate: Int

  public init(type: Int, startDate: Int, endDate: Int) {
    self.type = type
    self.startDate = startDate
    self.endDate = endDate
  }

  public static let pause = 1
  public static let resume = 2
  public static let lap = 3
  public static let segment = 7

  public var duration: TimeInterval { Double(endDate - startDate) / 1000 }
}

extension HealthWorkout {
  /// Statistics by type ID, e.g. `HKQuantityTypeIdentifierActiveEnergyBurned`.
  public var decodedStatistics: [String: WorkoutStatistic] {
    (try? JSONDecoder().decode([String: WorkoutStatistic].self, from: Data(statistics.utf8)))
      ?? [:]
  }

  public var decodedEvents: [WorkoutEvent] {
    (try? JSONDecoder().decode([WorkoutEvent].self, from: Data(events.utf8))) ?? []
  }

  /// From start to end, pauses included.
  public var elapsed: TimeInterval { Double(endDate - startDate) / 1000 }
}

/// One point of a workout route.
public struct RouteLocation: Equatable, Sendable {
  public var time: Date
  public var latitude: Double
  public var longitude: Double
  public var altitude: Double
  /// Meters a second, or negative if unknown.
  public var speed: Double

  public init(time: Date, latitude: Double, longitude: Double, altitude: Double, speed: Double) {
    self.time = time
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
    self.speed = speed
  }
}

/// One stretch of a route: a kilometer (the last one may be shorter) and how long it took.
public struct RouteSplit: Equatable, Sendable {
  public var distance: Double
  public var duration: TimeInterval

  public init(distance: Double, duration: TimeInterval) {
    self.distance = distance
    self.duration = duration
  }

  /// Seconds per kilometer.
  public var pace: TimeInterval { distance > 0 ? duration / distance * 1000 : 0 }
}

extension HealthDatabase {
  /// Up to `limit` workouts, newest first, starting before `before`.
  public static func workouts(before: Date? = nil, limit: Int, _ db: Database) throws
    -> [HealthWorkout]
  {
    let upper = before?.unixMilliseconds ?? .max
    return
      try HealthWorkout
      .where { $0.startDate < upper }
      .order { $0.startDate.desc() }
      .limit(limit)
      .fetchAll(db)
  }

  /// The route of a workout, if it has one: linked by HealthKit, or else recorded within it.
  public static func route(of workout: HealthWorkout, _ db: Database) throws
    -> HealthWorkoutRoute?
  {
    if let linked = try HealthWorkoutRoute.where({ $0.workout.eq(workout.id) }).fetchOne(db) {
      return linked
    }
    return
      try HealthWorkoutRoute
      .where {
        $0.workout.is(nil) && $0.startDate >= workout.startDate && $0.endDate <= workout.endDate
      }
      .fetchOne(db)
  }

  /// A route blob's locations: 44 little-endian bytes each, the time (Unix seconds), latitude
  /// and longitude as 64-bit floats, then altitude, horizontal and vertical accuracy, speed and
  /// course as 32-bit ones (`HealthWorkoutRoute` on the server). A trailing partial record is
  /// left out.
  public static func routeLocations(_ blob: Data) -> [RouteLocation] {
    let size = 44
    return blob.withUnsafeBytes { buffer in
      stride(from: 0, through: buffer.count - size, by: size).map { offset in
        func double(_ at: Int) -> Double {
          Double(
            bitPattern: UInt64(
              littleEndian: buffer.loadUnaligned(fromByteOffset: offset + at, as: UInt64.self)))
        }
        func float(_ at: Int) -> Double {
          Double(
            Float(
              bitPattern: UInt32(
                littleEndian: buffer.loadUnaligned(fromByteOffset: offset + at, as: UInt32.self))))
        }
        return RouteLocation(
          time: Date(timeIntervalSince1970: double(0)), latitude: double(8),
          longitude: double(16), altitude: float(24), speed: float(36))
      }
    }
  }

  /// The route cut into kilometers, each with how long it took.
  public static func splits(_ locations: [RouteLocation], every meters: Double = 1000)
    -> [RouteSplit]
  {
    guard var previous = locations.first else { return [] }
    var splits: [RouteSplit] = []
    var distance = 0.0
    var start = previous.time
    for location in locations.dropFirst() {
      distance += Self.distance(previous, location)
      if distance >= meters {
        splits.append(
          RouteSplit(distance: distance, duration: location.time.timeIntervalSince(start)))
        distance = 0
        start = location.time
      }
      previous = location
    }
    if distance > 0 {
      splits.append(
        RouteSplit(distance: distance, duration: previous.time.timeIntervalSince(start)))
    }
    return splits
  }

  /// Meters between two points, along the Earth's surface.
  static func distance(_ a: RouteLocation, _ b: RouteLocation) -> Double {
    let radius = 6_371_000.0
    let (lat1, lat2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
    let dLat = lat2 - lat1
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * radius * asin(min(1, sqrt(h)))
  }
}
