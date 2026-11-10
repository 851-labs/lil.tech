import Foundation
import HealthCatalog

/// What the `samples` tool says of a sample beyond its value (851-4166): where it came from (its
/// app and version, and its device, which a page lists once each, `SampleSources`), and its
/// metadata (only the keys lil health keeps, 851-4152), each key it reads turned into a plain
/// field (`details`), read as the server reads them
/// (`Services/api/src/health/tools/SampleDetails.ts`), so the two `samples` tools agree (the
/// conformance cases). Every field is left out when the sample doesn't have it.
///
/// The iPhone writes an `HKQuantity` as its description, a number with 6 significant digits and
/// a unit ("120 count/min", `HealthEncoder.json`), until 851-4150 keeps them whole: so quantities
/// are rounded to that, and a unit not listed here leaves the field out.
enum SampleDetails {
  /// Where a sample or correlation came from, as stored, its provenance's filled in.
  struct Stored {
    var sourceName: String
    var sourceBundleID: String
    /// JSON, or nil.
    var sourceRevision: String? = nil
    /// JSON, or nil.
    var device: String? = nil
  }

  /// What a sample's or correlation's metadata says, in `time`'s local times.
  static func details(_ metadata: [String: Any]?, time: ToolTime) -> HealthSampleDetails {
    var details = HealthSampleDetails()
    guard let metadata else { return details }
    for (key, set) in metadataFields { set(&details, metadata[key]) }
    if let earliest = number(metadata["HKDateOfEarliestDataUsedForEstimate"]),
      estimateDates.contains(earliest)
    {
      details.earliestDataUsedForEstimate = time.localTime(
        Date(timeIntervalSince1970: earliest / 1000))
    }
    return details
  }

  /// Apple's own devices' bundle IDs, `com.apple.health.` and the device's UUID.
  nonisolated(unsafe) static let appleDeviceBundleID =
    /com\.apple\.health\.[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/

  /// The dates an estimate's earliest data is shown for, 1970 to 2999, as Unix milliseconds, so
  /// both servers write them alike (HealthKit is from 2014); a date outside them is left out.
  static let estimateDates = 0.0..<32_503_680_000_000

  /// Sets a field from a metadata key's value, unless an earlier key set it.
  typealias Setter = @Sendable (inout HealthSampleDetails, Any?) -> Void

  static func set<Value>(
    _ field: any WritableKeyPath<HealthSampleDetails, Value?> & Sendable,
    _ read: @escaping @Sendable (Any?) -> Value?
  ) -> Setter {
    { details, value in
      if details[keyPath: field] == nil { details[keyPath: field] = read(value) }
    }
  }

  /// Each field read from one metadata key, in the order they're read. `sensorLocation` has two
  /// keys, heart rate's and body temperature's, and takes the first a sample has.
  static let metadataFields: [(String, Setter)] = [
    ("HKWasUserEntered", set(\.userEntered, boolean)),
    ("HKTimeZone", set(\.recordedTimeZone, text)),
    ("HKFoodType", set(\.food, text)),
    (
      "HKMetadataKeyHeartRateMotionContext",
      set(\.motionContext, named([nil, "sedentary", "active"]))
    ),
    (
      "HKMetadataKeyUserMotionContext",
      set(\.userMotionContext, named([nil, "stationary", "active"]))
    ),
    (
      "HKHeartRateSensorLocation",
      set(
        \.sensorLocation, named(["other", "chest", "wrist", "finger", "hand", "earLobe", "foot"]))
    ),
    (
      "HKBodyTemperatureSensorLocation",
      set(
        \.sensorLocation,
        named([
          "other", "armpit", "body", "ear", "finger", "gastroIntestinal", "mouth", "rectum", "toe",
          "earDrum", "temporalArtery", "forehead",
        ]))
    ),
    ("HKBloodGlucoseMealTime", set(\.mealTime, named([nil, "preprandial", "postprandial"]))),
    ("HKInsulinDeliveryReason", set(\.insulinDeliveryReason, named([nil, "basal", "bolus"]))),
    ("HKVO2MaxTestType", set(\.vo2MaxTestType, named(heartRateTestTypes + ["predictionStepTest"]))),
    ("HKVO2MaxValue", set(\.vo2Max, vo2Max)),
    ("HKLowCardioFitnessEventThreshold", set(\.lowCardioFitnessThreshold, vo2Max)),
    ("HKHeartRateEventThreshold", set(\.heartRateEventThreshold, beatsPerMinute)),
    (
      "HKMetadataKeyHeartRateRecoveryTestType",
      set(\.heartRateRecoveryTestType, named(heartRateTestTypes + ["stepTest"]))
    ),
    ("HKMetadataKeyHeartRateRecoveryActivityType", set(\.heartRateRecoveryActivity, activityName)),
    (
      "HKMetadataKeyHeartRateRecoveryActivityDuration",
      set(\.heartRateRecoveryActivityDuration, seconds)
    ),
    (
      "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate",
      set(\.maxObservedRecoveryHeartRate, beatsPerMinute)
    ),
    ("HKMetadataKeyAudioExposureLevel", set(\.audioExposureLevel, decibels)),
    ("HKMetadataKeyAudioExposureDuration", set(\.audioExposureDuration, seconds)),
    ("HKMetadataKeyHeadphoneGain", set(\.headphoneGain, decibels)),
    (
      "HKPhysicalEffortEstimationType",
      set(\.physicalEffortEstimationType, named([nil, "activityLookup", "deviceSensed"]))
    ),
    ("HKActivityType", set(\.activity, activityName)),
    (
      "HKMetadataKeyDevicePlacementSide",
      set(\.placementSide, named([nil, "left", "right", "central"]))
    ),
    ("HKMetadataKeyAppleDeviceCalibrated", set(\.deviceCalibrated, boolean)),
    ("HKAlgorithmVersion", set(\.algorithmVersion, number)),
    ("HKMetadataKeyQuantityClampedToLowerBound", set(\.clampedToLowerBound, boolean)),
    ("HKMetadataKeyQuantityClampedToUpperBound", set(\.clampedToUpperBound, boolean)),
    ("HKReferenceRangeLowerLimit", set(\.referenceRangeLowerLimit, number)),
    ("HKReferenceRangeUpperLimit", set(\.referenceRangeUpperLimit, number)),
    ("HKWasTakenInLab", set(\.takenInLab, boolean)),
    ("HKMetadataKeyWaterSalinity", set(\.waterSalinity, named([nil, "freshWater", "saltWater"]))),
    ("HKMetadataKeyMaximumLightIntensity", set(\.maximumLightIntensity, lux)),
    ("HKMenstrualCycleStart", set(\.menstrualCycleStart, boolean)),
    ("HKSexualActivityProtectionUsed", set(\.protectionUsed, boolean)),
  ]

  static let heartRateTestTypes: [String?] = [
    nil, "maxExercise", "predictionSubMaxExercise", "predictionNonExercise",
  ]

  // MARK: - Reading values

  /// A string unless it's blank: only spaces, tabs and line breaks, as on the server.
  static func text(_ value: Any?) -> String? {
    guard let string = value as? String,
      !string.unicodeScalars.allSatisfy({ " \t\n\r".unicodeScalars.contains($0) })
    else { return nil }
    return string
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

  /// A Boolean, or 0 or 1 from apps that write it as a number, as `HKIndoorWorkout` is read.
  static func boolean(_ value: Any?) -> Bool? {
    if isBoolean(value), let number = value as? NSNumber { return number.boolValue }
    switch number(value) {
    case 1: return true
    case 0: return false
    default: return nil
    }
  }

  /// The case at an enum's raw value, if it's a whole number with one (not set is nil).
  static func named(_ cases: [String?]) -> @Sendable (Any?) -> String? {
    { value in
      guard let raw = number(value), raw >= 0, raw.rounded() == raw, raw < Double(cases.count),
        let name = cases[Int(raw)]
      else { return nil }
      return name
    }
  }

  /// A workout activity's name, by its `HKWorkoutActivityType` raw value.
  static func activityName(_ value: Any?) -> String? {
    // Whole and below 10^15, so it makes an `Int`, as on the server.
    guard let raw = number(value), raw.rounded() == raw, abs(raw) < 1e15 else { return nil }
    return HealthCatalog.workoutActivityName(Int(raw))
  }

  /// A quantity's description in one unit, by the factor of each unit it's read in.
  static func quantity(_ factors: [String: Double]) -> @Sendable (Any?) -> Double? {
    { value in
      guard let description = value as? String,
        let match = description.wholeMatch(
          of: /([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?) (\S+)/),
        let number = Double(match.1), let factor = factors[String(match.2)]
      else { return nil }
      let converted = number * factor
      return converted.isFinite ? converted : nil
    }
  }

  static let beatsPerMinute = quantity(["count/min": 1, "count/s": 60])
  static let seconds = quantity(["ms": 0.001, "s": 1, "min": 60, "hr": 3600, "d": 86400])
  static let decibels = quantity(["dBASPL": 1])
  /// VO2 max, in mL/(kg·min): `HKQuantity` writes the unit `mL/min·kg`.
  static let vo2Max = quantity([
    "mL/min·kg": 1, "mL/kg·min": 1, "ml/min·kg": 1, "ml/kg·min": 1,
  ])
  static let lux = quantity(["lx": 1, "klx": 1000])

  // MARK: - Device

  /// The device's properties it has, else the device's name and manufacturer from the metadata,
  /// which apps without an `HKDevice` write; nil without any.
  static func device(_ device: [String: Any]?, metadata: [String: Any]?) -> HealthSampleDevice? {
    let result = HealthSampleDevice(
      name: text(device?["name"]) ?? text(metadata?["HKDeviceName"]),
      manufacturer: text(device?["manufacturer"]) ?? text(metadata?["HKDeviceManufacturerName"]),
      model: text(device?["model"]), hardwareVersion: text(device?["hardwareVersion"]),
      firmwareVersion: text(device?["firmwareVersion"]),
      softwareVersion: text(device?["softwareVersion"]))
    return result.isEmpty ? nil : result
  }

  /// A JSON column as an object, or nil if it's nil or isn't one.
  static func object(_ json: String?) -> [String: Any]? {
    guard let json else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
  }
}

/// A page's sources: each sample's app, version and device, listed once each in the order they
/// first appear, so a page of a Watch's readings doesn't repeat them, as the server's
/// `SampleSources`. Source revisions and devices repeat across a page, so each is read once.
struct SampleSources {
  private(set) var sources: [HealthSampleSource] = []
  private var indexes: [HealthSampleSource: Int] = [:]
  private var parsed: [String: [String: Any]?] = [:]

  /// The index in `sources` of where `stored` came from, `metadata` its metadata.
  mutating func index(of stored: SampleDetails.Stored, metadata: [String: Any]?) -> Int {
    let revision = object(stored.sourceRevision)
    let source = HealthSampleSource(
      name: stored.sourceName,
      bundleId: stored.sourceBundleID.wholeMatch(of: SampleDetails.appleDeviceBundleID) == nil
        ? stored.sourceBundleID : nil,
      version: SampleDetails.text(revision?["version"]),
      productType: SampleDetails.text(revision?["productType"]),
      operatingSystemVersion: SampleDetails.text(revision?["operatingSystemVersion"]),
      device: SampleDetails.device(object(stored.device), metadata: metadata))
    if let index = indexes[source] { return index }
    sources.append(source)
    indexes[source] = sources.count - 1
    return sources.count - 1
  }

  private mutating func object(_ json: String?) -> [String: Any]? {
    guard let json else { return nil }
    if let object = parsed[json] { return object }
    let object = SampleDetails.object(json)
    parsed[json] = .some(object)
    return object
  }
}
