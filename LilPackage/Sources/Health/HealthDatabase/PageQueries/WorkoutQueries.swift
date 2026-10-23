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
  public static let motionPaused = 5
  public static let motionResumed = 6
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

  /// When it was paused: from each pause (or motion pause) to the resume after it, or to the
  /// end.
  public var pauses: [DateInterval] {
    var pauses: [DateInterval] = []
    var pausedAt: Int?
    for event in decodedEvents.sorted(by: { $0.startDate < $1.startDate }) {
      switch event.type {
      case WorkoutEvent.pause, WorkoutEvent.motionPaused:
        pausedAt = pausedAt ?? event.startDate
      case WorkoutEvent.resume, WorkoutEvent.motionResumed:
        if let from = pausedAt, event.startDate > from {
          pauses.append(
            DateInterval(
              start: Date(unixMilliseconds: from), end: Date(unixMilliseconds: event.startDate)))
        }
        pausedAt = nil
      default:
        break
      }
    }
    if let from = pausedAt, endDate > from {
      pauses.append(
        DateInterval(start: Date(unixMilliseconds: from), end: Date(unixMilliseconds: endDate)))
    }
    return pauses
  }

  /// From start to end, pauses included.
  public var elapsed: TimeInterval { Double(endDate - startDate) / 1000 }

  /// The kinds of distance a workout can record, the usual ones first.
  public static let distanceTypes = [
    "HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierDistanceCycling",
    "HKQuantityTypeIdentifierDistanceSwimming", "HKQuantityTypeIdentifierDistanceWheelchair",
    "HKQuantityTypeIdentifierDistanceDownhillSnowSports",
    "HKQuantityTypeIdentifierDistanceCrossCountrySkiing",
    "HKQuantityTypeIdentifierDistancePaddleSports", "HKQuantityTypeIdentifierDistanceRowing",
    "HKQuantityTypeIdentifierDistanceSkatingSports",
  ]
  public static let activeEnergyType = "HKQuantityTypeIdentifierActiveEnergyBurned"
  public static let heartRateType = "HKQuantityTypeIdentifierHeartRate"

  /// The workout's distance in meters, whichever kind it recorded.
  public static func distance(in statistics: [String: WorkoutStatistic]) -> Double? {
    distanceStatistic(in: statistics)?.meters
  }

  /// Which kind of distance the workout recorded (the first of `distanceTypes` with a sum), and
  /// how far, in meters.
  public static func distanceStatistic(in statistics: [String: WorkoutStatistic]) -> (
    type: String, meters: Double
  )? {
    for type in distanceTypes {
      if let meters = statistics[type]?.sum { return (type, meters) }
    }
    return nil
  }

  /// The unit a swim's pool is measured in, from its lap length (`HKLapLength`, written as the
  /// quantity's description: "25 yd", "50 m"), or nil without one.
  public var lapLengthUnit: String? {
    guard let metadata,
      let object = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any],
      let (_, unit) = HealthDatabase.quantity(object["HKLapLength"]), !unit.isEmpty
    else { return nil }
    return unit
  }
}

extension HealthWorkoutRoute {
  /// From the route's start to its end.
  public var elapsed: TimeInterval { Double(endDate - startDate) / 1000 }
}

/// A workout's or a route's times, all ``HealthDatabase/workoutRoutes(limit:_:)`` needs of them.
struct RouteSpan {
  let id: String
  /// The workout a route is linked to.
  let workout: String?
  let startDate: Int
  let endDate: Int
  let locationCount: Int

  /// Whether a workout would show this route rather than `other`: it has more locations, or as
  /// many and comes first by ID.
  func isPicked(over other: RouteSpan) -> Bool {
    locationCount != other.locationCount ? locationCount > other.locationCount : id < other.id
  }

  static func newerFirst(_ a: RouteSpan, _ b: RouteSpan) -> Bool {
    (a.startDate, a.id) > (b.startDate, b.id)
  }
}

extension Array {
  /// The first index whose element is `true` for `predicate`, which is `false` for a prefix of
  /// the array and `true` for the rest.
  fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
    var (low, high) = (0, count)
    while low < high {
      let middle = (low + high) / 2
      if predicate(self[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }
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

/// One stretch of a route: a kilometer or a mile (the last one may be shorter), in meters, and
/// how long it took.
public struct RouteSplit: Equatable, Sendable {
  public var distance: Double
  public var duration: TimeInterval

  public init(distance: Double, duration: TimeInterval) {
    self.distance = distance
    self.duration = duration
  }
}

extension HealthDatabase {
  /// Up to `limit` of the workouts that start in `range`, newest first.
  public static func workouts(in range: Range<Date>, limit: Int, _ db: Database) throws
    -> [HealthWorkout]
  {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    return
      try HealthWorkout
      .where { $0.startDate >= lower && $0.startDate < upper }
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }

  /// How many workouts start in `range`, and their total duration (pauses left out), in seconds.
  public static func workoutTotals(in range: Range<Date>, _ db: Database) throws
    -> (count: Int, duration: TimeInterval)
  {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    let totals =
      try HealthWorkout
      .where { $0.startDate >= lower && $0.startDate < upper }
      .select { ($0.id.count(), $0.duration.sum()) }
      .fetchOne(db)
    return (totals?.0 ?? 0, totals?.1 ?? 0)
  }

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

  /// The route of a workout, if it has one with locations: the one HealthKit linked, or else
  /// one recorded during it. With several, the one with the most locations (then the first by
  /// ID, as ``workoutRoutes(limit:_:)`` picks).
  public static func route(of workout: HealthWorkout, _ db: Database) throws
    -> HealthWorkoutRoute?
  {
    let linked =
      try HealthWorkoutRoute
      .where { $0.workout.eq(workout.id) && $0.locations.isNot(nil) }
      .order { ($0.locationCount.desc(), $0.id) }
      .fetchOne(db)
    if let linked { return linked }
    return
      try HealthWorkoutRoute
      .where {
        $0.workout.is(nil) && $0.locations.isNot(nil) && $0.startDate < workout.endDate
          && $0.endDate > workout.startDate
      }
      .order { ($0.locationCount.desc(), $0.id) }
      .fetchOne(db)
  }

  /// What Workout Routes lists, each newest first: up to `limit` of the workouts with a route,
  /// and up to `limit` of the routes no workout's page shows (those ``route(of:_:)`` picks for
  /// none). Only routes with locations count, so each opens on a map.
  public static func workoutRoutes(limit: Int, _ db: Database) throws
    -> (workouts: [HealthWorkout], otherRoutes: [HealthWorkoutRoute])
  {
    // Every workout's and route's times, to pick in memory the route each workout shows, as
    // `route(of:)` does: a few columns of each, rather than a search of the routes for every
    // workout.
    let workoutTimes: [(String, Int, Int)] =
      try HealthWorkout.all.select { ($0.id, $0.startDate, $0.endDate) }.fetchAll(db)
    let routeTimes: [(String, String?, Int, Int, Int)] =
      try HealthWorkoutRoute
      .where { $0.locations.isNot(nil) }
      .select { ($0.id, $0.workout, $0.startDate, $0.endDate, $0.locationCount) }
      .fetchAll(db)
    let workouts = workoutTimes.map {
      RouteSpan(id: $0.0, workout: nil, startDate: $0.1, endDate: $0.2, locationCount: 0)
    }
    let routes = routeTimes.map {
      RouteSpan(id: $0.0, workout: $0.1, startDate: $0.2, endDate: $0.3, locationCount: $0.4)
    }
    let shown = shownRoutes(workouts: workouts, routes: routes)
    let withRoutes = workouts.filter { shown[$0.id] != nil }
      .sorted(by: RouteSpan.newerFirst).prefix(limit).map(\.id)
    let shownIDs = Set(shown.values)
    let others = routes.filter { !shownIDs.contains($0.id) }
      .sorted(by: RouteSpan.newerFirst).prefix(limit).map(\.id)
    return (
      try HealthWorkout
        .where { $0.id.in(withRoutes) }
        .order { ($0.startDate.desc(), $0.id.desc()) }
        .fetchAll(db),
      try HealthWorkoutRoute
        .where { $0.id.in(others) }
        .order { ($0.startDate.desc(), $0.id.desc()) }
        .fetchAll(db)
    )
  }

  /// The route each workout shows, by workout ID: its linked route with the most locations, or
  /// else the unlinked one recorded during it with the most.
  static func shownRoutes(workouts: [RouteSpan], routes: [RouteSpan]) -> [String: String] {
    var shown: [String: RouteSpan] = [:]
    let workoutIDs = Set(workouts.map(\.id))
    for route in routes {
      guard let workout = route.workout, workoutIDs.contains(workout) else { continue }
      if shown[workout].map(route.isPicked(over:)) ?? true { shown[workout] = route }
    }
    // Unlinked routes by start. One that starts more than the longest one's length before a
    // workout ends before it, so each workout looks at only the few that could overlap it.
    let unlinked = routes.filter { $0.workout == nil }.sorted { $0.startDate < $1.startDate }
    let longest = unlinked.map { $0.endDate - $0.startDate }.max() ?? 0
    for workout in workouts where shown[workout.id] == nil {
      let earliest = workout.startDate - longest
      var index = unlinked.partitioningIndex { $0.startDate > earliest }
      var best: RouteSpan?
      while index < unlinked.count, unlinked[index].startDate < workout.endDate {
        let route = unlinked[index]
        if route.endDate > workout.startDate, best.map(route.isPicked(over:)) ?? true {
          best = route
        }
        index += 1
      }
      shown[workout.id] = best
    }
    return shown.mapValues(\.id)
  }

  /// How far a route goes, in meters: the distance between each point and the next.
  public static func routeDistance(_ locations: [RouteLocation]) -> Double {
    zip(locations, locations.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
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

  /// The route cut into splits of `meters` (a kilometer, or a mile in the US and UK, 851-3176;
  /// the last one may be shorter), each with how long it took, leaving out the time it was
  /// paused. A split ends where the route crosses its distance, between two points, so the
  /// distance past it counts toward the next one.
  public static func splits(
    _ locations: [RouteLocation], pauses: [DateInterval] = [], every meters: Double = 1000
  ) -> [RouteSplit] {
    guard var previous = locations.first else { return [] }
    var splits: [RouteSplit] = []
    var covered = 0.0
    var start = previous.time
    /// Seconds from `from` to `to`, less the paused time between them.
    func moving(_ from: Date, _ to: Date) -> TimeInterval {
      let paused = pauses.reduce(0.0) { total, pause in
        let overlap = min(pause.end, to).timeIntervalSince(max(pause.start, from))
        return total + max(overlap, 0)
      }
      return max(to.timeIntervalSince(from) - paused, 0)
    }
    for location in locations.dropFirst() {
      let step = Self.distance(previous, location)
      var stepStart = previous.time
      var left = step
      // A step can cross more than one split (a GPS gap).
      while covered + left >= meters, left > 0 {
        let needed = meters - covered
        let crossing = stepStart.addingTimeInterval(
          location.time.timeIntervalSince(stepStart) * needed / left)
        splits.append(RouteSplit(distance: meters, duration: moving(start, crossing)))
        left -= needed
        covered = 0
        start = crossing
        stepStart = crossing
      }
      covered += left
      previous = location
    }
    if covered > 0.5 {
      splits.append(RouteSplit(distance: covered, duration: moving(start, previous.time)))
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
