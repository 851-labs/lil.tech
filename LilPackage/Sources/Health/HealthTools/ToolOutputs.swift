// Each tool's output, as the toolkit's output schemas have it (`HealthToolkit.ts`, and
// `mcp-tools.json`, which `lil-health mcp` serves): the same fields, names and meanings, so
// `--json` and the local MCP server answer as the remote one does. Every field is required, so
// optional ones encode as `null` rather than being left out, which Swift's synthesized `Codable`
// would do.

/// A tool's answer: JSON with `--json` (and from the MCP server), text otherwise.
public protocol HealthToolOutput: Codable, Equatable, Sendable {}

extension KeyedEncodingContainer {
  /// Encodes `nil` as `null`, rather than leaving the key out.
  mutating func encode<Value: Encodable>(_ value: Value?, _ key: Key) throws {
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
  /// Deprecated, always `false`: pins are retired (851-2990), and `metrics` are always Summary's
  /// everyday ones. Kept because it's in the tool's published output schema.
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
  /// Its entry in the page's `sources` (851-4166).
  public var sourceIndex: Int
  /// A quantity series' count and summary, or which of its values this is (851-4171); `nil`
  /// for a sample of one value.
  public var series: HealthSampleSeries?
  /// What its metadata says, each field only when the sample has it (851-4166).
  public var details: HealthSampleDetails

  public init(
    id: String, start: String, end: String, value: Double?, unit: String?, categoryValue: Int?,
    source: String, sourceIndex: Int, series: HealthSampleSeries? = nil,
    details: HealthSampleDetails = HealthSampleDetails()
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.value = value
    self.unit = unit
    self.categoryValue = categoryValue
    self.source = source
    self.sourceIndex = sourceIndex
    self.series = series
    self.details = details
  }

  private enum CodingKeys: String, CodingKey {
    case id, start, end, value, unit, categoryValue, source, sourceIndex, series
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    start = try container.decode(String.self, forKey: .start)
    end = try container.decode(String.self, forKey: .end)
    value = try container.decodeIfPresent(Double.self, forKey: .value)
    unit = try container.decodeIfPresent(String.self, forKey: .unit)
    categoryValue = try container.decodeIfPresent(Int.self, forKey: .categoryValue)
    source = try container.decode(String.self, forKey: .source)
    sourceIndex = try container.decode(Int.self, forKey: .sourceIndex)
    series = try container.decodeIfPresent(HealthSampleSeries.self, forKey: .series)
    details = try HealthSampleDetails(from: decoder)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(value, .value)
    try container.encode(unit, .unit)
    try container.encode(categoryValue, .categoryValue)
    try container.encode(source, .source)
    try container.encode(sourceIndex, .sourceIndex)
    try container.encodeIfPresent(series, forKey: .series)
    // Beside the fields above, in the same object.
    try details.encode(to: encoder)
  }
}

/// A quantity series (851-4171), as `samples` shows a sample that is one (`HealthSampleSeries`
/// in `HealthToolkit.ts`): its count and a discrete series' summary, or, listing its values
/// (`seriesValues`), the count and which value an item is. Fields that are nil are left out.
public struct HealthSampleSeries: Codable, Equatable, Sendable {
  public var count: Int
  public var index: Int?
  public var minimum: Double?
  public var maximum: Double?
  public var mostRecent: Double?
  public var mostRecentStart: String?
  public var mostRecentEnd: String?

  public init(
    count: Int, index: Int? = nil, minimum: Double? = nil, maximum: Double? = nil,
    mostRecent: Double? = nil, mostRecentStart: String? = nil, mostRecentEnd: String? = nil
  ) {
    self.count = count
    self.index = index
    self.minimum = minimum
    self.maximum = maximum
    self.mostRecent = mostRecent
    self.mostRecentStart = mostRecentStart
    self.mostRecentEnd = mostRecentEnd
  }
}

/// What a sample's metadata says (`sampleDetailFields` in `HealthToolkit.ts`, 851-4166), read
/// by `SampleDetails`. Every field is left out of the JSON when it's nil, as the toolkit's optional
/// keys are: synthesized `Codable` does that.
public struct HealthSampleDetails: Codable, Equatable, Sendable {
  public var userEntered: Bool?
  public var recordedTimeZone: String?
  /// A correlation's samples, by type.
  public var values: [HealthCorrelatedValue]?
  public var food: String?
  public var motionContext: String?
  public var userMotionContext: String?
  public var sensorLocation: String?
  public var mealTime: String?
  public var insulinDeliveryReason: String?
  public var vo2MaxTestType: String?
  public var vo2Max: Double?
  public var lowCardioFitnessThreshold: Double?
  public var heartRateEventThreshold: Double?
  public var heartRateRecoveryTestType: String?
  public var heartRateRecoveryActivity: String?
  public var heartRateRecoveryActivityDuration: Double?
  public var maxObservedRecoveryHeartRate: Double?
  public var audioExposureLevel: Double?
  public var audioExposureDuration: Double?
  public var headphoneGain: Double?
  public var physicalEffortEstimationType: String?
  public var activity: String?
  public var placementSide: String?
  public var deviceCalibrated: Bool?
  public var algorithmVersion: Double?
  public var earliestDataUsedForEstimate: String?
  public var clampedToLowerBound: Bool?
  public var clampedToUpperBound: Bool?
  public var referenceRangeLowerLimit: Double?
  public var referenceRangeUpperLimit: Double?
  public var takenInLab: Bool?
  public var waterSalinity: String?
  public var maximumLightIntensity: Double?
  public var menstrualCycleStart: Bool?
  public var protectionUsed: Bool?

  public init() {}
}

/// Where a page's samples came from (`HealthSampleSource` in `HealthToolkit.ts`, 851-4166): the
/// app or device, its version and the device that measured them, listed once a page. Optional
/// fields are left out of the JSON when they're nil.
public struct HealthSampleSource: Codable, Hashable, Sendable {
  public var name: String
  public var bundleId: String?
  public var version: String?
  public var productType: String?
  public var operatingSystemVersion: String?
  public var device: HealthSampleDevice?

  public init(
    name: String, bundleId: String? = nil, version: String? = nil, productType: String? = nil,
    operatingSystemVersion: String? = nil, device: HealthSampleDevice? = nil
  ) {
    self.name = name
    self.bundleId = bundleId
    self.version = version
    self.productType = productType
    self.operatingSystemVersion = operatingSystemVersion
    self.device = device
  }
}

/// The device that measured a sample: `HKDevice`'s properties lil health keeps, those it has.
public struct HealthSampleDevice: Codable, Hashable, Sendable {
  public var name: String?
  public var manufacturer: String?
  public var model: String?
  public var hardwareVersion: String?
  public var firmwareVersion: String?
  public var softwareVersion: String?

  public init(
    name: String? = nil, manufacturer: String? = nil, model: String? = nil,
    hardwareVersion: String? = nil, firmwareVersion: String? = nil, softwareVersion: String? = nil
  ) {
    self.name = name
    self.manufacturer = manufacturer
    self.model = model
    self.hardwareVersion = hardwareVersion
    self.firmwareVersion = firmwareVersion
    self.softwareVersion = softwareVersion
  }

  var isEmpty: Bool { self == HealthSampleDevice() }
}

/// One of a correlation's samples (blood pressure's systolic, a food's energy).
public struct HealthCorrelatedValue: Codable, Equatable, Sendable {
  public var type: String
  public var value: Double?
  public var unit: String?

  public init(type: String, value: Double?, unit: String?) {
    self.type = type
    self.value = value
    self.unit = unit
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, .type)
    try container.encode(value, .value)
    try container.encode(unit, .unit)
  }
}

public struct HealthSamplesResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var type: String
  public var samples: [HealthSampleItem]
  public var sources: [HealthSampleSource]
  public var nextCursor: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(range, .range)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(type, .type)
    try container.encode(samples, .samples)
    try container.encode(sources, .sources)
    try container.encode(nextCursor, .nextCursor)
  }
}

// MARK: - workouts

public struct HealthWorkoutItem: Codable, Equatable, Sendable {
  public var id: String
  public var activityType: Int
  public var activity: String
  /// `HKMetadataKeyWorkoutBrandName`, from the app that recorded it.
  public var name: String?
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
  /// Meters.
  public var elevationAscended: Double?
  public var indoor: Bool?
  /// `pool` or `openWater`.
  public var swimmingLocation: String?
  /// Whether a route with locations was recorded with it.
  public var hasRoute: Bool
  public var source: String
  /// A multisport workout's activities; empty for a workout of one.
  public var activities: [HealthWorkoutActivityItem]

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(activityType, .activityType)
    try container.encode(activity, .activity)
    try container.encode(name, .name)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(duration, .duration)
    try container.encode(activeEnergy, .activeEnergy)
    try container.encode(distance, .distance)
    try container.encode(averageHeartRate, .averageHeartRate)
    try container.encode(elevationAscended, .elevationAscended)
    try container.encode(indoor, .indoor)
    try container.encode(swimmingLocation, .swimmingLocation)
    try container.encode(hasRoute, .hasRoute)
    try container.encode(source, .source)
    try container.encode(activities, .activities)
  }
}

/// One of a multisport workout's activities.
public struct HealthWorkoutActivityItem: Codable, Equatable, Sendable {
  public var activityType: Int
  public var activity: String
  public var start: String
  /// `nil` while it was still going.
  public var end: String?
  /// Seconds, pauses left out.
  public var duration: Double
  public var indoor: Bool?
  /// `pool` or `openWater`.
  public var swimmingLocation: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(activityType, .activityType)
    try container.encode(activity, .activity)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(duration, .duration)
    try container.encode(indoor, .indoor)
    try container.encode(swimmingLocation, .swimmingLocation)
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

// MARK: - workout

/// One quantity type's statistics over a workout or one of its activities, in `unit`.
public struct HealthWorkoutStatistic: Codable, Equatable, Sendable {
  public var type: String
  /// The name Health shows for it, if the catalog knows the type.
  public var name: String?
  public var unit: String
  public var sum: Double?
  public var average: Double?
  public var minimum: Double?
  public var maximum: Double?
  public var mostRecent: Double?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, .type)
    try container.encode(name, .name)
    try container.encode(unit, .unit)
    try container.encode(sum, .sum)
    try container.encode(average, .average)
    try container.encode(minimum, .minimum)
    try container.encode(maximum, .maximum)
    try container.encode(mostRecent, .mostRecent)
  }
}

/// When a workout was paused, to when it resumed or ended.
public struct HealthWorkoutPause: Codable, Equatable, Sendable {
  public var start: String
  public var end: String
  /// Seconds.
  public var duration: Double
}

/// A workout's lap or segment.
public struct HealthWorkoutInterval: Codable, Equatable, Sendable {
  public var start: String
  public var end: String
  /// Seconds, from start to end.
  public var duration: Double
  /// `HKSwimmingStrokeStyle`'s name, e.g. `freestyle`.
  public var strokeStyle: String?
  public var swolf: Double?
  /// Meters.
  public var lapLength: Double?
  /// Meters per second.
  public var averageSpeed: Double?
  /// Meters per second.
  public var maximumSpeed: Double?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(duration, .duration)
    try container.encode(strokeStyle, .strokeStyle)
    try container.encode(swolf, .swolf)
    try container.encode(lapLength, .lapLength)
    try container.encode(averageSpeed, .averageSpeed)
    try container.encode(maximumSpeed, .maximumSpeed)
  }
}

/// One of a multisport workout's legs, with its own statistics.
public struct HealthWorkoutLeg: Codable, Equatable, Sendable {
  public var activityType: Int
  public var activity: String
  public var start: String
  /// `nil` while it was still going.
  public var end: String?
  /// Seconds, pauses left out.
  public var duration: Double
  public var indoor: Bool?
  /// `pool` or `openWater`.
  public var swimmingLocation: String?
  /// Meters.
  public var elevationAscended: Double?
  /// Meters.
  public var elevationDescended: Double?
  /// Meters per second.
  public var averageSpeed: Double?
  /// Meters per second.
  public var maximumSpeed: Double?
  /// kcal/hr·kg.
  public var averageMETs: Double?
  /// Meters.
  public var lapLength: Double?
  public var swolf: Double?
  public var statistics: [HealthWorkoutStatistic]

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(activityType, .activityType)
    try container.encode(activity, .activity)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(duration, .duration)
    try container.encode(indoor, .indoor)
    try container.encode(swimmingLocation, .swimmingLocation)
    try container.encode(elevationAscended, .elevationAscended)
    try container.encode(elevationDescended, .elevationDescended)
    try container.encode(averageSpeed, .averageSpeed)
    try container.encode(maximumSpeed, .maximumSpeed)
    try container.encode(averageMETs, .averageMETs)
    try container.encode(lapLength, .lapLength)
    try container.encode(swolf, .swolf)
    try container.encode(statistics, .statistics)
  }
}

/// One workout in full: what `workouts` says of it, and the rest.
public struct HealthWorkoutDetail: Codable, Equatable, Sendable {
  public var id: String
  public var activityType: Int
  public var activity: String
  public var name: String?
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
  /// Meters.
  public var elevationAscended: Double?
  public var indoor: Bool?
  /// `pool` or `openWater`.
  public var swimmingLocation: String?
  public var hasRoute: Bool
  public var source: String
  /// Meters.
  public var elevationDescended: Double?
  /// Meters per second.
  public var averageSpeed: Double?
  /// Meters per second.
  public var maximumSpeed: Double?
  /// kcal/hr·kg.
  public var averageMETs: Double?
  /// Meters.
  public var lapLength: Double?
  public var swolf: Double?
  /// `HKWeatherCondition`'s name, e.g. `clear`.
  public var weatherCondition: String?
  /// Degrees Celsius.
  public var weatherTemperature: Double?
  /// Percent, from 0 to 100.
  public var weatherHumidity: Double?
  public var statistics: [HealthWorkoutStatistic]
  public var pauseCount: Int
  public var pauses: [HealthWorkoutPause]
  public var lapCount: Int
  public var laps: [HealthWorkoutInterval]
  public var segmentCount: Int
  public var segments: [HealthWorkoutInterval]
  /// A multisport workout's legs; empty for a workout of one.
  public var activities: [HealthWorkoutLeg]

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(activityType, .activityType)
    try container.encode(activity, .activity)
    try container.encode(name, .name)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encode(duration, .duration)
    try container.encode(activeEnergy, .activeEnergy)
    try container.encode(distance, .distance)
    try container.encode(averageHeartRate, .averageHeartRate)
    try container.encode(elevationAscended, .elevationAscended)
    try container.encode(indoor, .indoor)
    try container.encode(swimmingLocation, .swimmingLocation)
    try container.encode(hasRoute, .hasRoute)
    try container.encode(source, .source)
    try container.encode(elevationDescended, .elevationDescended)
    try container.encode(averageSpeed, .averageSpeed)
    try container.encode(maximumSpeed, .maximumSpeed)
    try container.encode(averageMETs, .averageMETs)
    try container.encode(lapLength, .lapLength)
    try container.encode(swolf, .swolf)
    try container.encode(weatherCondition, .weatherCondition)
    try container.encode(weatherTemperature, .weatherTemperature)
    try container.encode(weatherHumidity, .weatherHumidity)
    try container.encode(statistics, .statistics)
    try container.encode(pauseCount, .pauseCount)
    try container.encode(pauses, .pauses)
    try container.encode(lapCount, .lapCount)
    try container.encode(laps, .laps)
    try container.encode(segmentCount, .segmentCount)
    try container.encode(segments, .segments)
    try container.encode(activities, .activities)
  }
}

public struct HealthWorkoutResult: HealthToolOutput {
  public var timeZone: String
  public var workout: HealthWorkoutDetail
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

// MARK: - activity_rings

/// One Activity ring's day: its value and goal, in `unit`.
public struct HealthActivityRing: Codable, Equatable, Sendable {
  public var value: Double
  public var goal: Double
  /// `kcal` or `min` for Move, `min` for Exercise, `hr` for Stand.
  public var unit: String
}

public struct HealthActivityDay: Codable, Equatable, Sendable {
  /// The iPhone's day, `YYYY-MM-DD`.
  public var date: String
  public var move: HealthActivityRing
  /// Nil without a goal, as without an Apple Watch.
  public var exercise: HealthActivityRing?
  public var stand: HealthActivityRing?
  public var paused: Bool

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(date, .date)
    try container.encode(move, .move)
    try container.encode(exercise, .exercise)
    try container.encode(stand, .stand)
    try container.encode(paused, .paused)
  }
}

public struct HealthActivityRingsResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var days: [HealthActivityDay]
}

// MARK: - state_of_mind

/// A State of Mind log, in the words of the Mac's State of Mind page.
public struct HealthStateOfMindItem: Codable, Equatable, Sendable {
  public var time: String
  /// `Momentary Emotion` or `Daily Mood` (`Unknown` for one a later iOS adds).
  public var kind: String
  /// From -1 (very unpleasant) to 1 (very pleasant).
  public var valence: Double
  /// E.g. `Slightly Pleasant`, or `Unknown` for one a later iOS adds.
  public var classification: String
  public var labels: [String]
  public var associations: [String]
  public var source: String
}

public struct HealthStateOfMindResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var logs: [HealthStateOfMindItem]
}

// MARK: - assessments

/// A GAD-7 or PHQ-9 assessment, in the words of the Mac's Anxiety Risk and Depression Risk pages.
public struct HealthAssessmentItem: Codable, Equatable, Sendable {
  public var type: String
  /// The type's name, e.g. `Anxiety Risk (GAD-7)`.
  public var name: String
  public var time: String
  public var score: Int
  public var maximumScore: Int
  /// E.g. `Mild`, or `Unknown` for one a later iOS adds.
  public var risk: String
  /// Each question's answer, in order, e.g. `Several days`.
  public var answers: [String]
}

public struct HealthAssessmentsResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var assessments: [HealthAssessmentItem]
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
