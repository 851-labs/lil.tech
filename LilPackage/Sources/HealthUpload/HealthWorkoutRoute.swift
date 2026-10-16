import CoreLocation
public import Foundation
public import HealthKit
import IssueReporting

/// A workout route's contents, read out of `HKWorkoutRoute` and its query (`init(_:store:)`), so
/// the encoding can be tested without HealthKit.
public struct WorkoutRouteRecord: Equatable, Sendable {
  public var id: UUID
  /// The workout it belongs to, if HealthKit links one.
  public var workout: UUID?
  public var locations: [Location]
  /// Times, source, device and metadata (`HealthEncoder.provenance(of:)`).
  public var provenance: [String: JSONValue]

  /// A location as Core Location reports it. Accuracies, speed and course are negative when
  /// unknown.
  public struct Location: Equatable, Sendable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    /// Meters.
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    /// Meters per second.
    public var speed: Double
    /// Degrees from true north.
    public var course: Double

    public init(
      timestamp: Date, latitude: Double, longitude: Double, altitude: Double,
      horizontalAccuracy: Double, verticalAccuracy: Double, speed: Double, course: Double
    ) {
      self.timestamp = timestamp
      self.latitude = latitude
      self.longitude = longitude
      self.altitude = altitude
      self.horizontalAccuracy = horizontalAccuracy
      self.verticalAccuracy = verticalAccuracy
      self.speed = speed
      self.course = course
    }
  }

  public init(
    id: UUID, workout: UUID?, locations: [Location], provenance: [String: JSONValue]
  ) {
    self.id = id
    self.workout = workout
    self.locations = locations
    self.provenance = provenance
  }
}

extension WorkoutRouteRecord {
  /// Reads a route out of HealthKit, with its locations. Throws `HealthReader.Locked` if the
  /// device locks meanwhile, and `HealthReader.SeriesUnavailable` if the query fails. A count
  /// that doesn't match is reported, and the locations are kept as read.
  public init(_ route: HKWorkoutRoute, store: HKHealthStore) async throws {
    let locations = try await HealthReader.readSeries(
      expected: route.count, HKWorkoutRouteQueryDescriptor(route).results(for: store)
    ) { location in
      Location(
        timestamp: location.timestamp, latitude: location.coordinate.latitude,
        longitude: location.coordinate.longitude, altitude: location.altitude,
        horizontalAccuracy: location.horizontalAccuracy,
        verticalAccuracy: location.verticalAccuracy, speed: location.speed,
        course: location.course)
    }
    self.init(
      id: route.uuid, workout: try await Self.workout(of: route, store: store),
      locations: locations, provenance: HealthEncoder.provenance(of: route))
  }

  /// The workout `route` belongs to. HealthKit only queries routes by workout, so it's found
  /// among the workouts its time overlaps. `nil` if none links it, or if they can't be read
  /// (reported): the route still goes up.
  private static func workout(of route: HKWorkoutRoute, store: HKHealthStore) async throws
    -> UUID?
  {
    do {
      let workouts = try await HKSampleQueryDescriptor(
        predicates: [
          .workout(HKQuery.predicateForSamples(withStart: route.startDate, end: route.endDate))
        ], sortDescriptors: [], limit: 10
      ).result(for: store)
      for workout in workouts {
        let routes = try await HKSampleQueryDescriptor(
          predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
          sortDescriptors: []
        ).result(for: store)
        if routes.contains(where: { $0.uuid == route.uuid }) { return workout.uuid }
      }
      return nil
    } catch {
      let mapped = HealthReader.Locked.mapped(error)
      if mapped is HealthReader.Locked || mapped is CancellationError { throw mapped }
      reportIssue(error)
      return nil
    }
  }
}

extension HealthEncoder {
  public static let workoutRouteEntity = "health_workout_route"

  /// A route's row, and its locations blob if it has any (`HealthWorkoutRoute` on the server).
  /// The row refers to the blob by its SHA-256.
  public static func workoutRoute(_ route: WorkoutRouteRecord) -> (
    mutation: HealthMutation, blob: Data?
  ) {
    let blob = route.locations.isEmpty ? nil : locationsBlob(route.locations)
    var row = route.provenance
    row["workout"] = route.workout.map { .string(id($0)) } ?? .null
    row["locationCount"] = .number(Double(route.locations.count))
    row["locations"] = blob.map { .string(HealthBlob.sha256($0)) } ?? .null
    return (.upsert(workoutRouteEntity, id: id(route.id), row: row), blob)
  }

  /// Bytes per location in `locationsBlob`.
  public static let locationBytes = 44

  /// Locations as a blob, 44 little-endian bytes each: the time (Unix seconds), latitude and
  /// longitude as 64-bit floats, then altitude, horizontal and vertical accuracy, speed and
  /// course as 32-bit floats.
  public static func locationsBlob(_ locations: [WorkoutRouteRecord.Location]) -> Data {
    var bytes = [UInt8](repeating: 0, count: locations.count * locationBytes)
    bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      func store<T: FixedWidthInteger>(_ value: T) {
        buffer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
        offset += MemoryLayout<T>.size
      }
      for location in locations {
        store(location.timestamp.timeIntervalSince1970.bitPattern)
        store(location.latitude.bitPattern)
        store(location.longitude.bitPattern)
        store(Float(location.altitude).bitPattern)
        store(Float(location.horizontalAccuracy).bitPattern)
        store(Float(location.verticalAccuracy).bitPattern)
        store(Float(location.speed).bitPattern)
        store(Float(location.course).bitPattern)
      }
    }
    return Data(bytes)
  }
}
