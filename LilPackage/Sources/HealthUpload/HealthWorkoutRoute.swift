import CoreLocation
public import Foundation
public import HealthKit
import IssueReporting

/// A workout route's contents, read out of `HKWorkoutRoute` and its query (`init(_:store:)`), so
/// the encoding can be tested without HealthKit.
public struct WorkoutRouteRecord: Equatable, Sendable {
  public var id: UUID
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

  public init(id: UUID, locations: [Location], provenance: [String: JSONValue]) {
    self.id = id
    self.locations = locations
    self.provenance = provenance
  }
}

extension WorkoutRouteRecord {
  /// Reads a route out of HealthKit, with its locations. Throws `HealthReader.Locked` if the
  /// device locks meanwhile, and `HealthReader.SeriesUnavailable` if the query fails. A count
  /// that doesn't match is reported, and the locations are kept as read.
  public init(_ route: HKWorkoutRoute, store: HKHealthStore) async throws {
    var locations: [Location] = []
    locations.reserveCapacity(route.count)
    do {
      for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
        locations.append(
          Location(
            timestamp: location.timestamp, latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude, altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy, speed: location.speed,
            course: location.course))
      }
    } catch {
      let mapped = HealthReader.Locked.mapped(error)
      if mapped is HealthReader.Locked || mapped is CancellationError { throw mapped }
      throw HealthReader.SeriesUnavailable(expected: route.count, read: locations.count)
    }
    try Task.checkCancellation()
    if locations.count != route.count {
      reportIssue(HealthReader.SeriesCountMismatch(expected: route.count, read: locations.count))
    }
    self.init(id: route.uuid, locations: locations, provenance: HealthEncoder.provenance(of: route))
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
    var data = Data(capacity: locations.count * locationBytes)
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    for location in locations {
      append(location.timestamp.timeIntervalSince1970.bitPattern)
      append(location.latitude.bitPattern)
      append(location.longitude.bitPattern)
      for value in [
        location.altitude, location.horizontalAccuracy, location.verticalAccuracy, location.speed,
        location.course,
      ] {
        append(Float(value).bitPattern)
      }
    }
    return data
  }
}
