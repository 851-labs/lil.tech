public import Foundation

/// The cards' dataset as a HealthKit would hold it, for the iPhone's side of the conformance cases
/// (851-3201): its samples and workouts, each with its source and device, after every batch's
/// upserts and deletes. The uploaded statistics (`health_statistic`) have no form in HealthKit,
/// which totals its own samples, so they're left out, and the cases whose totals come from them
/// skip the iPhone (docs/decisions/cards.md › Conformance and tolerance).
public struct ConformanceSamples: Sendable {
  public var samples: [Sample]
  public var workouts: [Workout]
  /// Every source in the dataset's samples and workouts, sorted, including those whose every
  /// record was deleted later: the iPhone writes each one's from an app of its own, the
  /// first source's from the first app, and so on.
  public var sources: [String]

  /// A quantity sample (with `value` and `unit`) or a category sample (with `categoryValue`).
  public struct Sample: Sendable {
    /// Its ID in the dataset, a lowercase UUID, which `first`'s and `latest`'s ties sort by.
    public var id: String
    public var type: String
    /// Unix milliseconds.
    public var start: Int
    public var end: Int
    public var value: Double?
    /// The value's unit, as HealthKit writes it (`count/min`, `kg`).
    public var unit: String?
    public var categoryValue: Int?
    public var source: String
    /// The sample's own device, or its provenance record's.
    public var device: Device?
  }

  public struct Workout: Sendable {
    public var id: String
    /// `HKWorkoutActivityType`'s raw value.
    public var activityType: Int
    public var start: Int
    public var end: Int
    public var source: String
    /// Its metadata's `HKIndoorWorkout`, as the dataset has it (a Boolean, or 0 or 1).
    public var indoor: NSNumber?
    /// Its activities, as the Mac and the server read them: all of them, or none if one can't
    /// be read.
    public var activities: [Activity] = []
  }

  /// One of a workout's activities, with what says where it was.
  public struct Activity: Sendable {
    /// `HKWorkoutActivityType`'s raw value.
    public var activityType: Int
    public var start: Int
    public var end: Int
    /// Its configuration's `HKWorkoutSessionLocationType` raw value.
    public var locationType: Int?
    /// Its configuration's `HKWorkoutSwimmingLocationType` raw value.
    public var swimmingLocationType: Int?
    /// Its metadata's `HKIndoorWorkout`.
    public var indoor: NSNumber?
  }

  /// What a sample says of the device that recorded it, as `HKDevice` has it.
  public struct Device: Sendable, Equatable {
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var hardwareVersion: String?
    public var softwareVersion: String?
  }

  /// The cards' dataset: the Health tools', then the cards' batches, as
  /// `CardConformanceCase.dataset()` reads it.
  public static func cards() throws -> ConformanceSamples {
    try ConformanceSamples(
      try ConformanceBatch.read(ConformanceFiles.cards.appending(path: "dataset.json")))
  }

  public init(_ batches: [ConformanceBatch]) throws {
    // Each record's device, if it has one.
    var provenance: [String: Device?] = [:]
    // By entity and ID, in the order they were first written.
    var rows: [String: (order: Int, entity: String, id: String, row: [String: Any])] = [:]
    var sources: Set<String> = []
    var written = 0
    for batch in batches {
      for line in batch.lines {
        guard let entity = line["entity"] as? String, let id = line["id"] as? String,
          let op = line["op"] as? String
        else { throw ConformanceError("a line without an entity, ID or op") }
        guard ["health_sample", "health_workout", "health_provenance"].contains(entity) else {
          continue
        }
        let key = "\(entity) \(id)"
        switch op {
        case "delete":
          rows[key] = nil
          if entity == "health_provenance" { provenance[id] = nil }
        case "upsert":
          guard let row = line["row"] as? [String: Any] else {
            throw ConformanceError("\(entity) \(id) has no row")
          }
          if entity == "health_provenance" {
            provenance[id] = .some((row["device"] as? [String: Any]).map(Device.init))
            continue
          }
          guard let source = row["sourceBundleId"] as? String else {
            throw ConformanceError("\(entity) \(id) has no source")
          }
          sources.insert(source)
          rows[key] = (rows[key]?.order ?? written, entity, id, row)
          written += 1
        default:
          throw ConformanceError("\(entity) \(id): unknown op \(op)")
        }
      }
    }
    samples = []
    workouts = []
    for (_, entity, id, row) in rows.values.sorted(by: { $0.order < $1.order }) {
      guard let start = row["startDate"] as? Int, let end = row["endDate"] as? Int,
        let source = row["sourceBundleId"] as? String
      else { throw ConformanceError("\(entity) \(id) has no dates") }
      if entity == "health_workout" {
        guard let activityType = row["activityType"] as? Int else {
          throw ConformanceError("workout \(id) has no activity type")
        }
        workouts.append(
          Workout(
            id: id, activityType: activityType, start: start, end: end, source: source,
            indoor: (row["metadata"] as? [String: Any])?["HKIndoorWorkout"] as? NSNumber,
            activities: Self.activities(row["activities"])))
        continue
      }
      guard let type = row["type"] as? String else {
        throw ConformanceError("sample \(id) has no type")
      }
      var device = (row["device"] as? [String: Any]).map(Device.init)
      if device == nil, let record = row["provenance"] as? String {
        guard let recorded = provenance[record] else {
          throw ConformanceError("sample \(id): no provenance record \(record)")
        }
        device = recorded
      }
      samples.append(
        Sample(
          id: id, type: type, start: start, end: end,
          value: (row["value"] as? NSNumber)?.doubleValue, unit: row["unit"] as? String,
          categoryValue: row["categoryValue"] as? Int, source: source, device: device))
    }
    self.sources = sources.sorted()
  }

  /// A workout's activities as the Mac reads them (`HealthWorkout.decodedActivities`): all of
  /// them, or none if one can't be read, such as a location type written as a string.
  static func activities(_ value: Any?) -> [Activity] {
    guard let items = value as? [[String: Any]] else { return [] }
    var activities: [Activity] = []
    for item in items {
      // Missing or null, or a number.
      func optionalInt(_ key: String) -> Int?? {
        switch item[key] {
        case nil, is NSNull: .some(nil)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
          .some(number.intValue)
        default: nil
        }
      }
      guard let activityType = item["activityType"] as? Int,
        let start = item["startDate"] as? Int, let end = item["endDate"] as? Int,
        let locationType = optionalInt("locationType"),
        let swimmingLocationType = optionalInt("swimmingLocationType")
      else { return [] }
      activities.append(
        Activity(
          activityType: activityType, start: start, end: end, locationType: locationType,
          swimmingLocationType: swimmingLocationType,
          indoor: (item["metadata"] as? [String: Any])?["HKIndoorWorkout"] as? NSNumber))
    }
    return activities
  }

  /// The samples and workouts of one source.
  public func of(source: String) -> ConformanceSamples {
    var part = self
    part.samples = samples.filter { $0.source == source }
    part.workouts = workouts.filter { $0.source == source }
    return part
  }
}

extension ConformanceSamples.Device {
  init(_ row: [String: Any]) {
    self.init(
      name: row["name"] as? String, manufacturer: row["manufacturer"] as? String,
      model: row["model"] as? String, hardwareVersion: row["hardwareVersion"] as? String,
      softwareVersion: row["softwareVersion"] as? String)
  }
}
