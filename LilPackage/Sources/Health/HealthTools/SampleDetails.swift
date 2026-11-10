import Foundation
import HealthCatalog

/// What the `samples` tool says of a sample beyond its value (851-4166): where it came from (its
/// app and version, and its device, which a page lists once each, `SampleSources`), and its
/// metadata (only the keys lil health keeps, 851-4152), each key it reads turned into a plain
/// field (`details`), read as the server reads them
/// (`Services/api/src/health/tools/SampleDetails.ts`), so the two `samples` tools agree (the
/// conformance cases). Every field is left out when the sample doesn't have it. Each key's value
/// is read as `HealthMetadataValues` reads it (851-4170): a quantity in a unit it isn't read in,
/// or a value of another kind, leaves the field out.
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
    for set in metadataFields { set(&details, metadata) }
    if let earliest = HealthMetadataValues.value(
      "HKDateOfEarliestDataUsedForEstimate", in: metadata)?.double,
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

  /// Sets a field from a metadata key's value (`HealthMetadataValues`), unless an earlier key
  /// set it.
  typealias Setter = @Sendable (inout HealthSampleDetails, [String: Any]) -> Void

  /// `field`'s setter from `key`, whose kind must read values of the field's type.
  static func set<Value>(
    _ field: any WritableKeyPath<HealthSampleDetails, Value?> & Sendable, _ key: String
  ) -> Setter {
    let kind = HealthMetadataValues.kinds[key]
    assert(
      kind.map { HealthMetadataValues.valueType(of: $0) == Value.self } == true,
      "\(key) isn't read as \(Value.self)")
    return { details, metadata in
      guard details[keyPath: field] == nil, let kind,
        let value = HealthMetadataValues.read(kind, metadata[key])
      else { return }
      switch value {
      case .text(let text): details[keyPath: field] = text as? Value
      case .number(let number): details[keyPath: field] = number as? Value
      case .boolean(let boolean): details[keyPath: field] = boolean as? Value
      }
    }
  }

  /// Each field and the metadata key it's read from, in the order they're read.
  /// `sensorLocation` has two keys, heart rate's and body temperature's, and takes the first a
  /// sample has.
  static let metadataFields: [Setter] = [
    set(\.userEntered, "HKWasUserEntered"),
    set(\.recordedTimeZone, "HKTimeZone"),
    set(\.food, "HKFoodType"),
    set(\.motionContext, "HKMetadataKeyHeartRateMotionContext"),
    set(\.userMotionContext, "HKMetadataKeyUserMotionContext"),
    set(\.sensorLocation, "HKHeartRateSensorLocation"),
    set(\.sensorLocation, "HKBodyTemperatureSensorLocation"),
    set(\.mealTime, "HKBloodGlucoseMealTime"),
    set(\.insulinDeliveryReason, "HKInsulinDeliveryReason"),
    set(\.vo2MaxTestType, "HKVO2MaxTestType"),
    set(\.vo2Max, "HKVO2MaxValue"),
    set(\.lowCardioFitnessThreshold, "HKLowCardioFitnessEventThreshold"),
    set(\.heartRateEventThreshold, "HKHeartRateEventThreshold"),
    set(\.heartRateRecoveryTestType, "HKMetadataKeyHeartRateRecoveryTestType"),
    set(\.heartRateRecoveryActivity, "HKMetadataKeyHeartRateRecoveryActivityType"),
    set(\.heartRateRecoveryActivityDuration, "HKMetadataKeyHeartRateRecoveryActivityDuration"),
    set(
      \.maxObservedRecoveryHeartRate, "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate"),
    set(\.audioExposureLevel, "HKMetadataKeyAudioExposureLevel"),
    set(\.audioExposureDuration, "HKMetadataKeyAudioExposureDuration"),
    set(\.headphoneGain, "HKMetadataKeyHeadphoneGain"),
    set(\.physicalEffortEstimationType, "HKPhysicalEffortEstimationType"),
    set(\.activity, "HKActivityType"),
    set(\.placementSide, "HKMetadataKeyDevicePlacementSide"),
    set(\.deviceCalibrated, "HKMetadataKeyAppleDeviceCalibrated"),
    set(\.algorithmVersion, "HKAlgorithmVersion"),
    set(\.clampedToLowerBound, "HKMetadataKeyQuantityClampedToLowerBound"),
    set(\.clampedToUpperBound, "HKMetadataKeyQuantityClampedToUpperBound"),
    set(\.referenceRangeLowerLimit, "HKReferenceRangeLowerLimit"),
    set(\.referenceRangeUpperLimit, "HKReferenceRangeUpperLimit"),
    set(\.takenInLab, "HKWasTakenInLab"),
    set(\.waterSalinity, "HKMetadataKeyWaterSalinity"),
    set(\.maximumLightIntensity, "HKMetadataKeyMaximumLightIntensity"),
    set(\.menstrualCycleStart, "HKMenstrualCycleStart"),
    set(\.protectionUsed, "HKSexualActivityProtectionUsed"),
  ]

  // MARK: - Device

  /// The device's properties it has, else the device's name and manufacturer from the metadata,
  /// which apps without an `HKDevice` write; nil without any.
  static func device(_ device: [String: Any]?, metadata: [String: Any]?) -> HealthSampleDevice? {
    let result = HealthSampleDevice(
      name: HealthMetadataValues.text(device?["name"])
        ?? HealthMetadataValues.value("HKDeviceName", in: metadata)?.string,
      manufacturer: HealthMetadataValues.text(device?["manufacturer"])
        ?? HealthMetadataValues.value("HKDeviceManufacturerName", in: metadata)?.string,
      model: HealthMetadataValues.text(device?["model"]),
      hardwareVersion: HealthMetadataValues.text(device?["hardwareVersion"]),
      firmwareVersion: HealthMetadataValues.text(device?["firmwareVersion"]),
      softwareVersion: HealthMetadataValues.text(device?["softwareVersion"]))
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
      version: HealthMetadataValues.text(revision?["version"]),
      productType: HealthMetadataValues.text(revision?["productType"]),
      operatingSystemVersion: HealthMetadataValues.text(revision?["operatingSystemVersion"]),
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
