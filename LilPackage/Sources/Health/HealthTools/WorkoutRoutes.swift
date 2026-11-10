import Foundation
import HealthDatabase
public import SQLiteData

// The route tools (851-4164): `workout_routes` lists routes from their rows, and `workout_route`
// and `workout_route_points` read one route's points from its blob, as the remote server does
// (`Services/api/src/health/tools/WorkoutRoutes.ts`), rule for rule. Routes are precise
// locations, so `workout_route` gives a summary and a simplified shape, and every point only
// comes a page at a time from `workout_route_points`, as the privacy policy says (851-4157).

extension HealthTools {
  /// The most routes `workout_routes` lists.
  public static let workoutRoutesLimit = 100
  /// The most points `workout_route`'s simplified shape keeps.
  public static let routeShapeLimit = 500
  /// The shape's first tolerance, in meters, doubled until it keeps few enough points.
  public static let routeShapeTolerance = 5.0
  /// The most points `workout_route_points` returns, and how many it returns by default.
  public static let routePointsLimit = 1000
  public static let routePointsDefaultLimit = 500

  // MARK: - workout_routes

  /// The routes with points that start in the period, newest first, at most
  /// `workoutRoutesLimit`, with how many there are.
  public func workoutRoutes(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthWorkoutRoutesResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let (lower, upper) = (period.start.unixMilliseconds, period.end.unixMilliseconds)
    let inPeriod = HealthWorkoutRoute.where {
      $0.locations.isNot(nil) && $0.startDate >= lower && $0.startDate < upper
    }
    let count = try inPeriod.select { $0.id.count() }.fetchOne(db) ?? 0
    let routes =
      try inPeriod
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(Self.workoutRoutesLimit)
      .fetchAll(db)
    let zones = RecordedZones()
    return HealthWorkoutRoutesResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: count,
      routes: routes.map {
        Self.routeItem($0, pointCount: $0.locationCount, time: time, zones: zones)
      })
  }

  // MARK: - workout_route

  /// One route in summary, by its ID or its workout's: distance, elevation, bounds, where it
  /// starts and ends, and its simplified shape.
  public func workoutRoute(id: String, timeZone: String? = nil, _ db: Database) throws
    -> HealthWorkoutRouteResult
  {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let route = try Self.route(id: id, db)
    let points = try routePoints(route)
    let (gain, loss) = Self.elevation(points)
    func area(_ point: RouteLocation?) -> HealthRouteCoordinate? {
      point.map {
        HealthRouteCoordinate(
          latitude: Self.rounded($0.latitude, 1000), longitude: Self.rounded($0.longitude, 1000))
      }
    }
    let item = Self.routeItem(
      route, pointCount: points.count, time: time, zones: RecordedZones())
    return HealthWorkoutRouteResult(
      timeZone: time.name,
      route: HealthWorkoutRouteDetail(
        id: item.id, workout: item.workout, start: item.start, end: item.end,
        recordedTimeZone: item.recordedTimeZone, recordedStart: item.recordedStart,
        recordedEnd: item.recordedEnd, duration: item.duration, pointCount: item.pointCount,
        source: item.source,
        distance: HealthDatabase.routeDistance(points), elevationGain: gain, elevationLoss: loss,
        bounds: Self.bounds(points), startArea: area(points.first), endArea: area(points.last),
        simplified: Self.shape(points, time: time)))
  }

  // MARK: - workout_route_points

  /// A page of a route's points, in order. The cursor is the index of the page's first point.
  public func workoutRoutePoints(
    id: String, timeZone: String? = nil, cursor: String? = nil, limit: Int? = nil,
    _ db: Database
  ) throws -> HealthWorkoutRoutePointsResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    // Checked before the points, which may have to be downloaded.
    let limit = limit ?? Self.routePointsDefaultLimit
    guard (1...Self.routePointsLimit).contains(limit) else {
      throw HealthToolError("The limit must be from 1 to \(Self.routePointsLimit).")
    }
    let invalidCursor = { (cursor: String) in
      HealthToolError("Invalid cursor: \(cursor). Pass the previous page's nextCursor.")
    }
    let index = try cursor.map { cursor in
      guard let index = Self.cursorIndex(cursor) else { throw invalidCursor(cursor) }
      return index
    }
    let route = try Self.route(id: id, db)
    let points = try routePoints(route)
    if let cursor, let index, index > points.count { throw invalidCursor(cursor) }
    let start = index ?? 0
    let end = min(start + limit, points.count)
    return HealthWorkoutRoutePointsResult(
      timeZone: time.name, id: route.id, pointCount: points.count,
      points: points[start..<end].map { point in
        HealthRoutePoint(
          time: time.localTime(point.time), latitude: point.latitude,
          longitude: point.longitude, altitude: Self.altitude(point),
          horizontalAccuracy: Self.known(point.horizontalAccuracy),
          verticalAccuracy: Self.known(point.verticalAccuracy), speed: Self.known(point.speed),
          course: Self.known(point.course))
      },
      nextCursor: end < points.count ? String(end) : nil)
  }

  // MARK: - Reading routes

  /// The route `id` names: the route with that ID, if it has points; else the route of the
  /// workout with that ID, as its page finds it (`HealthDatabase.route(of:)`).
  static func route(id: String, _ db: Database) throws -> HealthWorkoutRoute {
    if let route = try HealthWorkoutRoute.where({ $0.id.eq(id) && $0.locations.isNot(nil) })
      .fetchOne(db)
    {
      return route
    }
    guard let workout = try HealthWorkout.where({ $0.id.eq(id) }).fetchOne(db) else {
      throw HealthToolError(
        "No workout or route with ID \(id). workouts and workout_routes list them, with their IDs."
      )
    }
    guard let route = try HealthDatabase.route(of: workout, db) else {
      throw HealthToolError(
        "The workout \(id) has no route: it was recorded without GPS (hasRoute is false).")
    }
    return route
  }

  /// The times a point can have, in Unix seconds: from 2000 to 2999, the tools' years.
  private static let pointTimes = 946_684_800.0..<32_503_680_000.0

  /// A route's points, from its blob, leaving out any whose coordinates aren't valid (a negative
  /// horizontal accuracy, as Core Location marks them, or not finite numbers) or whose time is
  /// outside 2000 to 2999.
  func routePoints(_ route: HealthWorkoutRoute) throws -> [RouteLocation] {
    guard let sha256 = route.locations else {
      throw HealthToolError("The route's points aren't on the server. Try again later.")
    }
    return HealthDatabase.routeLocations(try blob(sha256)).filter {
      $0.horizontalAccuracy >= 0 && $0.latitude.isFinite && $0.longitude.isFinite
        && Self.pointTimes.contains($0.time.timeIntervalSince1970)
    }
  }

  /// What both lists say of a route, `zones` looking up the zones routes were recorded in.
  private static func routeItem(
    _ route: HealthWorkoutRoute, pointCount: Int, time: ToolTime, zones: RecordedZones
  ) -> HealthWorkoutRouteItem {
    let recorded = zones.times(json: route.metadata, start: route.startDate, end: route.endDate)
    return HealthWorkoutRouteItem(
      id: route.id, workout: route.workout,
      start: time.localTime(Date(unixMilliseconds: route.startDate)),
      end: time.localTime(Date(unixMilliseconds: route.endDate)),
      recordedTimeZone: recorded.timeZone, recordedStart: recorded.start,
      recordedEnd: recorded.end,
      duration: Double(route.endDate - route.startDate) / 1000, pointCount: pointCount,
      source: route.sourceName)
  }

  /// A cursor's index: 1 to 9 digits, as the remote server reads it (`cursorIndex`), or `nil`.
  static func cursorIndex(_ cursor: String) -> Int? {
    guard (1...9).contains(cursor.utf8.count), cursor.utf8.allSatisfy({ (48...57).contains($0) })
    else { return nil }
    return Int(cursor)
  }

  /// `value` to the places `factor` gives (100 for 2), halves away from zero, as the remote
  /// server rounds them, and never `-0`.
  static func rounded(_ value: Double, _ factor: Double) -> Double {
    let rounded = (abs(value) * factor).rounded(.toNearestOrAwayFromZero) / factor
    return (value < 0 ? -rounded : rounded) + 0
  }

  /// A 32-bit value a device may not have known (negative), to 2 places, or `nil`.
  private static func known(_ value: Double) -> Double? {
    value.isFinite && value >= 0 ? rounded(value, 100) : nil
  }

  /// A point's altitude, or `nil` when its vertical accuracy says it's unknown, as Core Location
  /// does.
  private static func altitude(_ point: RouteLocation) -> Double? {
    point.verticalAccuracy >= 0 && point.altitude.isFinite ? rounded(point.altitude, 100) : nil
  }

  /// Meters climbed and descended between the points with a known altitude, or `nil`s without
  /// two.
  private static func elevation(_ points: [RouteLocation]) -> (gain: Double?, loss: Double?) {
    let altitudes = points.filter { $0.verticalAccuracy >= 0 && $0.altitude.isFinite }
      .map(\.altitude)
    guard altitudes.count >= 2 else { return (nil, nil) }
    var (gain, loss) = (0.0, 0.0)
    for (previous, next) in zip(altitudes, altitudes.dropFirst()) {
      let change = next - previous
      if change > 0 { gain += change } else { loss -= change }
    }
    return (rounded(gain, 100), rounded(loss, 100))
  }

  /// The box the points fit in, to 5 places, or `nil` without any.
  private static func bounds(_ points: [RouteLocation]) -> HealthRouteBounds? {
    guard !points.isEmpty else { return nil }
    var (south, west) = (Double.infinity, Double.infinity)
    var (north, east) = (-Double.infinity, -Double.infinity)
    for point in points {
      south = min(south, point.latitude)
      north = max(north, point.latitude)
      west = min(west, point.longitude)
      east = max(east, point.longitude)
    }
    return HealthRouteBounds(
      south: rounded(south, 100_000), west: rounded(west, 100_000),
      north: rounded(north, 100_000), east: rounded(east, 100_000))
  }

  /// The simplified shape: at `routeShapeTolerance`, doubled until it keeps `routeShapeLimit`
  /// or fewer.
  private static func shape(_ points: [RouteLocation], time: ToolTime) -> HealthRouteShape {
    let kept = keptBelow(points)
    var tolerance = routeShapeTolerance
    while kept.count(where: { $0 > tolerance }) > routeShapeLimit { tolerance *= 2 }
    let shown = points.indices.filter { kept[$0] > tolerance }.map { points[$0] }
    return HealthRouteShape(
      tolerance: tolerance, pointCount: shown.count,
      points: shown.map { point in
        HealthRouteShapePoint(
          time: time.localTime(point.time), latitude: rounded(point.latitude, 100_000),
          longitude: rounded(point.longitude, 100_000), altitude: altitude(point))
      })
  }

  /// The tolerance below which Ramer-Douglas-Peucker keeps each point, in meters: at a tolerance,
  /// it keeps the first and last points, and every point further than it from the segment
  /// between the points kept around it. Which point splits a span (the furthest, the first of
  /// points as far) doesn't depend on the tolerance, only whether it splits, so one pass finds
  /// them all: a point is kept below its distance from its span's segment, and below its span's
  /// own split point's. Distances are on a flat projection around the first point (meters east
  /// and north).
  static func keptBelow(_ points: [RouteLocation]) -> [Double] {
    var kept = [Double](repeating: .infinity, count: points.count)
    guard points.count > 2 else { return kept }
    let origin = points[0]
    let radius = 6_371_000.0
    let east = Double.pi / 180 * radius * cos(origin.latitude * .pi / 180)
    let north = Double.pi / 180 * radius
    let x = points.map { ($0.longitude - origin.longitude) * east }
    let y = points.map { ($0.latitude - origin.latitude) * north }
    func fromSegment(_ index: Int, _ start: Int, _ end: Int) -> Double {
      let (dx, dy) = (x[end] - x[start], y[end] - y[start])
      let length = dx * dx + dy * dy
      let along =
        length == 0
        ? 0 : min(1, max(0, ((x[index] - x[start]) * dx + (y[index] - y[start]) * dy) / length))
      let (ex, ey) = (x[start] + along * dx - x[index], y[start] + along * dy - y[index])
      return (ex * ex + ey * ey).squareRoot()
    }
    var spans = [(0, points.count - 1, Double.infinity)]
    while let (start, end, below) = spans.popLast() {
      var furthest: Int?
      var furthestDistance = -1.0
      for index in (start + 1)..<end {
        let away = fromSegment(index, start, end)
        if away > furthestDistance {
          furthest = index
          furthestDistance = away
        }
      }
      guard let furthest else { continue }
      kept[furthest] = min(furthestDistance, below)
      spans.append((start, furthest, kept[furthest]))
      spans.append((furthest, end, kept[furthest]))
    }
    return kept
  }
}

// MARK: - Outputs

public struct HealthWorkoutRouteItem: Codable, Equatable, Sendable {
  public var id: String
  /// The workout HealthKit linked it to.
  public var workout: String?
  public var start: String
  public var end: String
  /// The zone it was recorded in (`HKTimeZone`), when it's a name the tools take, and its start
  /// and end on that zone's clock (851-4177); `nil` without one, and left out of the JSON.
  public var recordedTimeZone: String? = nil
  public var recordedStart: String? = nil
  public var recordedEnd: String? = nil
  /// Seconds.
  public var duration: Double
  public var pointCount: Int
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(workout, .workout)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    try container.encodeIfPresent(recordedStart, forKey: .recordedStart)
    try container.encodeIfPresent(recordedEnd, forKey: .recordedEnd)
    try container.encode(duration, .duration)
    try container.encode(pointCount, .pointCount)
    try container.encode(source, .source)
  }
}

public struct HealthWorkoutRoutesResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var routes: [HealthWorkoutRouteItem]
}

public struct HealthRouteCoordinate: Codable, Equatable, Sendable {
  public var latitude: Double
  public var longitude: Double
}

public struct HealthRouteBounds: Codable, Equatable, Sendable {
  public var south: Double
  public var west: Double
  public var north: Double
  public var east: Double
}

public struct HealthRouteShapePoint: Codable, Equatable, Sendable {
  public var time: String
  public var latitude: Double
  public var longitude: Double
  /// Meters, if known.
  public var altitude: Double?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(time, .time)
    try container.encode(latitude, .latitude)
    try container.encode(longitude, .longitude)
    try container.encode(altitude, .altitude)
  }
}

public struct HealthRouteShape: Codable, Equatable, Sendable {
  /// Meters.
  public var tolerance: Double
  public var pointCount: Int
  public var points: [HealthRouteShapePoint]
}

public struct HealthWorkoutRouteDetail: Codable, Equatable, Sendable {
  public var id: String
  public var workout: String?
  public var start: String
  public var end: String
  /// The zone it was recorded in (`HKTimeZone`), when it's a name the tools take, and its start
  /// and end on that zone's clock (851-4177); `nil` without one, and left out of the JSON.
  public var recordedTimeZone: String? = nil
  public var recordedStart: String? = nil
  public var recordedEnd: String? = nil
  public var duration: Double
  public var pointCount: Int
  public var source: String
  /// Meters.
  public var distance: Double
  /// Meters, without two points with a known altitude `nil`.
  public var elevationGain: Double?
  public var elevationLoss: Double?
  public var bounds: HealthRouteBounds?
  public var startArea: HealthRouteCoordinate?
  public var endArea: HealthRouteCoordinate?
  public var simplified: HealthRouteShape

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(workout, .workout)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    try container.encodeIfPresent(recordedStart, forKey: .recordedStart)
    try container.encodeIfPresent(recordedEnd, forKey: .recordedEnd)
    try container.encode(duration, .duration)
    try container.encode(pointCount, .pointCount)
    try container.encode(source, .source)
    try container.encode(distance, .distance)
    try container.encode(elevationGain, .elevationGain)
    try container.encode(elevationLoss, .elevationLoss)
    try container.encode(bounds, .bounds)
    try container.encode(startArea, .startArea)
    try container.encode(endArea, .endArea)
    try container.encode(simplified, .simplified)
  }
}

public struct HealthWorkoutRouteResult: HealthToolOutput {
  public var timeZone: String
  public var route: HealthWorkoutRouteDetail
}

public struct HealthRoutePoint: Codable, Equatable, Sendable {
  public var time: String
  public var latitude: Double
  public var longitude: Double
  /// Meters, if known.
  public var altitude: Double?
  /// Meters, if known.
  public var horizontalAccuracy: Double?
  public var verticalAccuracy: Double?
  /// Meters a second, if known.
  public var speed: Double?
  /// Degrees from true north, if known.
  public var course: Double?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(time, .time)
    try container.encode(latitude, .latitude)
    try container.encode(longitude, .longitude)
    try container.encode(altitude, .altitude)
    try container.encode(horizontalAccuracy, .horizontalAccuracy)
    try container.encode(verticalAccuracy, .verticalAccuracy)
    try container.encode(speed, .speed)
    try container.encode(course, .course)
  }
}

public struct HealthWorkoutRoutePointsResult: HealthToolOutput {
  public var timeZone: String
  public var id: String
  public var pointCount: Int
  public var points: [HealthRoutePoint]
  public var nextCursor: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(id, .id)
    try container.encode(pointCount, .pointCount)
    try container.encode(points, .points)
    try container.encode(nextCursor, .nextCursor)
  }
}
