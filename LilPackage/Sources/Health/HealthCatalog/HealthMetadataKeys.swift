import Foundation

/// One of HealthKit's metadata keys (`HKMetadataKey…`), and whether lil health keeps it.
public struct HealthMetadataKey: Sendable, Equatable {
  /// The constant's name in the SDK, e.g. `HKMetadataKeyTimeZone`.
  public let constant: String
  /// Its value, the key HealthKit puts in an object's `metadata`, e.g. `HKTimeZone`.
  public let key: String
  public let kept: Bool
  /// The unit its value is uploaded in, when HealthKit's value is an `HKQuantity` (851-4150).
  public let quantityUnit: QuantityUnit?

  /// The unit a metadata quantity is uploaded in: `{ "value": 84.6, "unit": "m" }`.
  public enum QuantityUnit: Sendable, Equatable {
    /// One unit for the key, as `HKUnit`'s `unitString` writes it (`"m"`, `"kcal/hr·kg"`).
    case unit(String)
    /// The unit of the sample it's on (the catalog's unit for the sample's type), for a key
    /// whose quantity is the sample's own kind (`HKMetadataKeySessionEstimate`).
    case sample
  }
}

extension HealthCatalog {
  /// Every metadata key in HealthKit's SDK, each kept or dropped (851-4152; the reasons are in
  /// `docs/decisions/health.md` › Metadata). An object's metadata goes up with only the kept keys
  /// (`keptMetadata`), and the server drops the others from what older iPhones send and from what
  /// it stored before (`Services/api/src/health/HealthMetadata.ts`). Any other key is dropped:
  /// other apps' own keys, Apple's private ones, and keys a newer SDK adds until they're listed
  /// here, which `HealthCatalogSDKTests` asks for.
  ///
  /// Kept: what a value means or how it was measured, which the apps and tools use or will
  /// (851-4156). Dropped: identifiers (serial and lot numbers, other apps' record IDs), signatures
  /// and sync bookkeeping, which nothing needs.
  public static let healthKitMetadataKeys: [HealthMetadataKey] = [
    // Every object
    kept("HKMetadataKeyTimeZone", "HKTimeZone"),
    kept("HKMetadataKeyWasUserEntered", "HKWasUserEntered"),
    dropped("HKMetadataKeySyncIdentifier", "HKMetadataKeySyncIdentifier"),
    dropped("HKMetadataKeySyncVersion", "HKMetadataKeySyncVersion"),
    dropped("HKMetadataKeyExternalUUID", "HKExternalUUID"),
    // The device
    kept("HKMetadataKeyDeviceName", "HKDeviceName"),
    kept("HKMetadataKeyDeviceManufacturerName", "HKDeviceManufacturerName"),
    dropped("HKMetadataKeyDeviceSerialNumber", "HKDeviceSerialNumber"),
    dropped("HKMetadataKeyUDIDeviceIdentifier", "HKUDIDeviceIdentifier"),
    dropped("HKMetadataKeyUDIProductionIdentifier", "HKUDIProductionIdentifier"),
    dropped("HKMetadataKeyDigitalSignature", "HKDigitalSignature"),
    kept("HKMetadataKeyAppleDeviceCalibrated", "HKMetadataKeyAppleDeviceCalibrated"),
    kept("HKMetadataKeyDevicePlacementSide", "HKMetadataKeyDevicePlacementSide"),
    // Estimates and measurements
    kept("HKMetadataKeyAlgorithmVersion", "HKAlgorithmVersion"),
    kept("HKMetadataKeyAppleECGAlgorithmVersion", "HKMetadataKeyAppleECGAlgorithmVersion"),
    kept(
      "HKMetadataKeyDateOfEarliestDataUsedForEstimate", "HKDateOfEarliestDataUsedForEstimate"),
    kept("HKMetadataKeySessionEstimate", "HKMetadataKeySessionEstimate", .sample),
    kept("HKMetadataKeyQuantityClampedToLowerBound", "HKMetadataKeyQuantityClampedToLowerBound"),
    kept("HKMetadataKeyQuantityClampedToUpperBound", "HKMetadataKeyQuantityClampedToUpperBound"),
    kept("HKMetadataKeyReferenceRangeLowerLimit", "HKReferenceRangeLowerLimit"),
    kept("HKMetadataKeyReferenceRangeUpperLimit", "HKReferenceRangeUpperLimit"),
    kept("HKMetadataKeyWasTakenInLab", "HKWasTakenInLab"),
    kept("HKMetadataKeyUserMotionContext", "HKMetadataKeyUserMotionContext"),
    kept("HKMetadataKeyBarometricPressure", "HKMetadataKeyBarometricPressure", .unit("kPa")),
    kept("HKMetadataKeyWaterSalinity", "HKMetadataKeyWaterSalinity"),
    kept("HKMetadataKeyMaximumLightIntensity", "HKMetadataKeyMaximumLightIntensity", .unit("lx")),
    kept("HKMetadataKeyPhysicalEffortEstimationType", "HKPhysicalEffortEstimationType"),
    kept("HKMetadataKeyActivityType", "HKActivityType"),
    // Heart
    kept("HKMetadataKeyHeartRateMotionContext", "HKMetadataKeyHeartRateMotionContext"),
    kept("HKMetadataKeyHeartRateSensorLocation", "HKHeartRateSensorLocation"),
    kept("HKMetadataKeyHeartRateEventThreshold", "HKHeartRateEventThreshold", .unit("count/min")),
    kept(
      "HKMetadataKeyHeartRateRecoveryTestType", "HKMetadataKeyHeartRateRecoveryTestType"),
    kept(
      "HKMetadataKeyHeartRateRecoveryActivityType", "HKMetadataKeyHeartRateRecoveryActivityType"),
    kept(
      "HKMetadataKeyHeartRateRecoveryActivityDuration",
      "HKMetadataKeyHeartRateRecoveryActivityDuration", .unit("s")),
    kept(
      "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate",
      "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate", .unit("count/min")),
    kept("HKMetadataKeyVO2MaxTestType", "HKVO2MaxTestType"),
    kept("HKMetadataKeyVO2MaxValue", "HKVO2MaxValue", .unit("mL/min·kg")),
    kept(
      "HKMetadataKeyLowCardioFitnessEventThreshold", "HKLowCardioFitnessEventThreshold",
      .unit("mL/min·kg")),
    // Hearing
    kept("HKMetadataKeyAudioExposureLevel", "HKMetadataKeyAudioExposureLevel", .unit("dBASPL")),
    kept("HKMetadataKeyAudioExposureDuration", "HKMetadataKeyAudioExposureDuration", .unit("s")),
    kept("HKMetadataKeyHeadphoneGain", "HKMetadataKeyHeadphoneGain", .unit("dBASPL")),
    // Clinical, cycle tracking and nutrition
    kept("HKMetadataKeyBloodGlucoseMealTime", "HKBloodGlucoseMealTime"),
    kept("HKMetadataKeyInsulinDeliveryReason", "HKInsulinDeliveryReason"),
    kept("HKMetadataKeyBodyTemperatureSensorLocation", "HKBodyTemperatureSensorLocation"),
    kept("HKMetadataKeyMenstrualCycleStart", "HKMenstrualCycleStart"),
    kept("HKMetadataKeySexualActivityProtectionUsed", "HKSexualActivityProtectionUsed"),
    kept("HKMetadataKeyFoodType", "HKFoodType"),
    kept(
      "HKMetadataKeyGlassesPrescriptionDescription", "HKMetadataKeyGlassesPrescriptionDescription"),
    // Workouts
    kept("HKMetadataKeyIndoorWorkout", "HKIndoorWorkout"),
    kept("HKMetadataKeySwimmingLocationType", "HKSwimmingLocationType"),
    kept("HKMetadataKeyWorkoutBrandName", "HKWorkoutBrandName"),
    kept("HKMetadataKeyElevationAscended", "HKElevationAscended", .unit("m")),
    kept("HKMetadataKeyElevationDescended", "HKElevationDescended", .unit("m")),
    kept("HKMetadataKeyAverageSpeed", "HKAverageSpeed", .unit("m/s")),
    kept("HKMetadataKeyMaximumSpeed", "HKMaximumSpeed", .unit("m/s")),
    kept("HKMetadataKeyAverageMETs", "HKAverageMETs", .unit("kcal/hr·kg")),
    kept("HKMetadataKeyLapLength", "HKLapLength", .unit("m")),
    kept("HKMetadataKeySwimmingStrokeStyle", "HKSwimmingStrokeStyle"),
    kept("HKMetadataKeySWOLFScore", "HKSWOLFScore"),
    kept("HKMetadataKeyAlpineSlopeGrade", "HKAlpineSlopeGrade", .unit("%")),
    kept("HKMetadataKeyWeatherCondition", "HKWeatherCondition"),
    kept("HKMetadataKeyWeatherTemperature", "HKWeatherTemperature", .unit("degC")),
    kept("HKMetadataKeyWeatherHumidity", "HKWeatherHumidity", .unit("%")),
    kept("HKMetadataKeyCoachedWorkout", "HKCoachedWorkout"),
    kept("HKMetadataKeyGroupFitness", "HKGroupFitness"),
    kept("HKMetadataKeyAppleFitnessPlusSession", "HKMetadataKeyAppleFitnessPlusSession"),
    dropped(
      "HKMetadataKeyAppleFitnessPlusCatalogIdentifier",
      "HKMetadataKeyAppleFitnessPlusCatalogIdentifier"),
    kept("HKMetadataKeyCrossTrainerDistance", "HKCrossTrainerDistance", .unit("m")),
    kept("HKMetadataKeyIndoorBikeDistance", "HKIndoorBikeDistance", .unit("m")),
    kept("HKMetadataKeyFitnessMachineDuration", "HKFitnessMachineDuration", .unit("s")),
    kept(
      "HKMetadataKeyCyclingFunctionalThresholdPowerTestType",
      "HKCyclingCyclingFunctionalThresholdPowerTestType"),
  ]

  /// Keys that aren't HealthKit's but are kept: lil health's own, the WorkoutKit plan the
  /// iPhone adds to a workout's metadata (`HealthEncoder.workoutPlanKey`, 851-4030).
  static let otherKeptMetadataKeys = ["LilWorkoutPlan"]

  /// Every metadata key lil health keeps. Any other is dropped.
  public static let keptMetadataKeys: Set<String> = Set(
    healthKitMetadataKeys.filter(\.kept).map(\.key) + otherKeptMetadataKeys)

  /// `metadata` with only the keys lil health keeps, or nil if none are left.
  public static func keptMetadata<Value>(_ metadata: [String: Value]) -> [String: Value]? {
    let kept = metadata.filter { keptMetadataKeys.contains($0.key) }
    return kept.isEmpty ? nil : kept
  }

  /// `HKDevice`'s properties the iPhone uploads. Its `localIdentifier` and
  /// `udiDeviceIdentifier`, which identify one device (a serial number, a Bluetooth address),
  /// are dropped.
  public static let keptDeviceProperties = [
    "name", "manufacturer", "model", "hardwareVersion", "firmwareVersion", "softwareVersion",
  ]

  /// Each kept key whose value is an `HKQuantity`, and the unit it's uploaded in (851-4150):
  /// the iPhone writes it as `{ value, unit }` in that unit, rather than its description.
  public static let metadataQuantityUnits: [String: HealthMetadataKey.QuantityUnit] =
    Dictionary(
      uniqueKeysWithValues: healthKitMetadataKeys.compactMap { key in
        key.quantityUnit.map { (key.key, $0) }
      })

  private static func kept(
    _ constant: String, _ key: String, _ quantityUnit: HealthMetadataKey.QuantityUnit? = nil
  ) -> HealthMetadataKey {
    HealthMetadataKey(constant: constant, key: key, kept: true, quantityUnit: quantityUnit)
  }

  private static func dropped(_ constant: String, _ key: String) -> HealthMetadataKey {
    HealthMetadataKey(constant: constant, key: key, kept: false, quantityUnit: nil)
  }
}
