// Each tool's output, as the toolkit's output schemas have it (`HealthToolkit.ts`, and
// `mcp-tools.json`, which `lil-health mcp` serves): the same fields, names and meanings, so
// `--json` and the local MCP server answer as the remote one does. Every field is required, so
// optional ones encode as `null` rather than being left out, which Swift's synthesized `Codable`
// would do.

/// A tool's answer: JSON with `--json` (and from the MCP server), text otherwise.
public protocol HealthToolOutput: Codable, Equatable, Sendable {}

extension KeyedEncodingContainer {
  /// Encodes `nil` as `null`, rather than leaving the key out.
  fileprivate mutating func encode<Value: Encodable>(_ value: Value?, _ key: Key) throws {
    try encode(value, forKey: key)
  }
}

// MARK: - summary

public struct HealthSummaryMetric: Codable, Equatable, Sendable {
  public var type: String
  public var unit: String?
  public var latest: Latest?
  public var today: Double?
  public var last7Days: Double?

  public struct Latest: Codable, Equatable, Sendable {
    public var start: String
    public var end: String
    public var value: Double?
    public var categoryValue: Int?

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(start, .start)
      try container.encode(end, .end)
      try container.encode(value, .value)
      try container.encode(categoryValue, .categoryValue)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, .type)
    try container.encode(unit, .unit)
    try container.encode(latest, .latest)
    try container.encode(today, .today)
    try container.encode(last7Days, .last7Days)
  }
}

public struct HealthSummaryResult: HealthToolOutput {
  public var timeZone: String
  public var date: String
  public var pinned: Bool
  public var metrics: [HealthSummaryMetric]
  public var workouts: Workouts

  public struct Workouts: Codable, Equatable, Sendable {
    public var count: Int
    /// Seconds.
    public var duration: Double
  }
}

// MARK: - list_types

public struct HealthTypeInfo: Codable, Equatable, Sendable {
  public var type: String
  public var name: String
  public var category: String?
  public var kind: String
  public var unit: String?
  public var cumulative: Bool
  public var first: String
  public var last: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, .type)
    try container.encode(name, .name)
    try container.encode(category, .category)
    try container.encode(kind, .kind)
    try container.encode(unit, .unit)
    try container.encode(cumulative, .cumulative)
    try container.encode(first, .first)
    try container.encode(last, .last)
  }
}

public struct HealthTypesResult: HealthToolOutput {
  public var timeZone: String
  public var types: [HealthTypeInfo]
}

// MARK: - metric

public struct HealthMetricBucket: Codable, Equatable, Sendable {
  public var start: String
  public var value: Double?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(start, .start)
    try container.encode(value, .value)
  }
}

public struct HealthMetricResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var type: String
  public var unit: String?
  public var statistic: String
  public var value: Double?
  public var buckets: [HealthMetricBucket]

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(range, .range)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(type, .type)
    try container.encode(unit, .unit)
    try container.encode(statistic, .statistic)
    try container.encode(value, .value)
    try container.encode(buckets, .buckets)
  }
}

// MARK: - samples

public struct HealthSampleItem: Codable, Equatable, Sendable {
  public var id: String
  public var start: String
  public var end: String
  public var value: Double?
  public var unit: String?
  public var categoryValue: Int?
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(value, .value)
    try container.encode(unit, .unit)
    try container.encode(categoryValue, .categoryValue)
    try container.encode(source, .source)
  }
}

public struct HealthSamplesResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var type: String
  public var samples: [HealthSampleItem]
  public var nextCursor: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(range, .range)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(type, .type)
    try container.encode(samples, .samples)
    try container.encode(nextCursor, .nextCursor)
  }
}

// MARK: - workouts

public struct HealthWorkoutItem: Codable, Equatable, Sendable {
  public var id: String
  public var activityType: Int
  public var activity: String
  public var start: String
  public var end: String
  /// Seconds, pauses left out.
  public var duration: Double
  /// Kilocalories.
  public var activeEnergy: Double?
  /// Meters.
  public var distance: Double?
  /// Beats per minute.
  public var averageHeartRate: Double?
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(activityType, .activityType)
    try container.encode(activity, .activity)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(duration, .duration)
    try container.encode(activeEnergy, .activeEnergy)
    try container.encode(distance, .distance)
    try container.encode(averageHeartRate, .averageHeartRate)
    try container.encode(source, .source)
  }
}

public struct HealthWorkoutsResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  /// Seconds.
  public var duration: Double
  public var workouts: [HealthWorkoutItem]
}

// MARK: - sleep

public struct HealthSleepNight: Codable, Equatable, Sendable {
  /// The day the night ends on.
  public var date: String
  public var start: String
  public var end: String
  // Seconds, each.
  public var inBed: Double
  public var asleep: Double
  public var awake: Double
  public var core: Double
  public var deep: Double
  public var rem: Double
  public var unspecified: Double
}

public struct HealthSleepResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var nights: [HealthSleepNight]
}

// MARK: - medications

public struct HealthMedicationAdherence: Codable, Equatable, Sendable {
  public var scheduled: Int
  public var taken: Int
  public var asNeeded: Int
}

public struct HealthMedicationItem: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var healthName: String
  public var form: String
  public var archived: Bool
  public var scheduled: Bool
  public var last7Days: HealthMedicationAdherence
  public var last30Days: HealthMedicationAdherence
  public var lastTaken: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(name, .name)
    try container.encode(healthName, .healthName)
    try container.encode(form, .form)
    try container.encode(archived, .archived)
    try container.encode(scheduled, .scheduled)
    try container.encode(last7Days, .last7Days)
    try container.encode(last30Days, .last30Days)
    try container.encode(lastTaken, .lastTaken)
  }
}

public struct HealthMedicationsResult: HealthToolOutput {
  public var timeZone: String
  public var medications: [HealthMedicationItem]
}

// MARK: - health_details

public struct HealthLens: Codable, Equatable, Sendable {
  public var sphere: Double?
  public var cylinder: Double?
  public var axis: Double?
  public var addPower: Double?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sphere, .sphere)
    try container.encode(cylinder, .cylinder)
    try container.encode(axis, .axis)
    try container.encode(addPower, .addPower)
  }
}

public struct HealthVisionPrescriptionItem: Codable, Equatable, Sendable {
  public var id: String
  /// `glasses` or `contacts`.
  public var kind: String
  public var issued: String
  public var expires: String?
  public var brand: String?
  public var rightEye: HealthLens?
  public var leftEye: HealthLens?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(kind, .kind)
    try container.encode(issued, .issued)
    try container.encode(expires, .expires)
    try container.encode(brand, .brand)
    try container.encode(rightEye, .rightEye)
    try container.encode(leftEye, .leftEye)
  }
}

public struct HealthDetailsResult: HealthToolOutput {
  public var timeZone: String
  public var dateOfBirth: String?
  public var age: Int?
  public var sex: String?
  public var bloodType: String?
  public var fitzpatrickSkinType: String?
  public var wheelchairUse: Bool?
  public var visionPrescriptions: [HealthVisionPrescriptionItem]

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(dateOfBirth, .dateOfBirth)
    try container.encode(age, .age)
    try container.encode(sex, .sex)
    try container.encode(bloodType, .bloodType)
    try container.encode(fitzpatrickSkinType, .fitzpatrickSkinType)
    try container.encode(wheelchairUse, .wheelchairUse)
    try container.encode(visionPrescriptions, .visionPrescriptions)
  }
}

// MARK: - search

public struct HealthSearchType: Codable, Equatable, Sendable {
  public var type: String
  public var name: String
  public var category: String?
  public var hasData: Bool

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, .type)
    try container.encode(name, .name)
    try container.encode(category, .category)
    try container.encode(hasData, .hasData)
  }
}

public struct HealthSearchMedication: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
}

public struct HealthSearchResult: HealthToolOutput {
  public var types: [HealthSearchType]
  public var medications: [HealthSearchMedication]
}

// MARK: - sync_status

public struct HealthSyncIPhone: Codable, Equatable, Sendable {
  public var device: String
  public var pairedWithWatch: Bool
  public var lastReported: String
  public var statisticsSource: Bool
}

public struct HealthSyncStatusResult: HealthToolOutput {
  public var timeZone: String
  public var latestSample: String?
  public var iPhones: [HealthSyncIPhone]

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(latestSample, .latestSample)
    try container.encode(iPhones, .iPhones)
  }
}
