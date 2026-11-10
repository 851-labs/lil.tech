import Foundation

/// One of HealthKit's metadata keys (`HKMetadataKey…`), and whether lil health keeps it.
public struct HealthMetadataKey: Sendable, Equatable {
  /// The constant's name in the SDK, e.g. `HKMetadataKeyTimeZone`.
  public let constant: String
  /// Its value, the key HealthKit puts in an object's `metadata`, e.g. `HKTimeZone`.
  public let key: String
  public let kept: Bool
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
    kept("HKMetadataKeySessionEstimate", "HKMetadataKeySessionEstimate"),
    kept("HKMetadataKeyQuantityClampedToLowerBound", "HKMetadataKeyQuantityClampedToLowerBound"),
    kept("HKMetadataKeyQuantityClampedToUpperBound", "HKMetadataKeyQuantityClampedToUpperBound"),
    kept("HKMetadataKeyReferenceRangeLowerLimit", "HKReferenceRangeLowerLimit"),
    kept("HKMetadataKeyReferenceRangeUpperLimit", "HKReferenceRangeUpperLimit"),
    kept("HKMetadataKeyWasTakenInLab", "HKWasTakenInLab"),
    kept("HKMetadataKeyUserMotionContext", "HKMetadataKeyUserMotionContext"),
    kept("HKMetadataKeyBarometricPressure", "HKMetadataKeyBarometricPressure"),
    kept("HKMetadataKeyWaterSalinity", "HKMetadataKeyWaterSalinity"),
    kept("HKMetadataKeyMaximumLightIntensity", "HKMetadataKeyMaximumLightIntensity"),
    kept("HKMetadataKeyPhysicalEffortEstimationType", "HKPhysicalEffortEstimationType"),
    kept("HKMetadataKeyActivityType", "HKActivityType"),
    // Heart
    kept("HKMetadataKeyHeartRateMotionContext", "HKMetadataKeyHeartRateMotionContext"),
    kept("HKMetadataKeyHeartRateSensorLocation", "HKHeartRateSensorLocation"),
    kept("HKMetadataKeyHeartRateEventThreshold", "HKHeartRateEventThreshold"),
    kept(
      "HKMetadataKeyHeartRateRecoveryTestType", "HKMetadataKeyHeartRateRecoveryTestType"),
    kept(
      "HKMetadataKeyHeartRateRecoveryActivityType", "HKMetadataKeyHeartRateRecoveryActivityType"),
    kept(
      "HKMetadataKeyHeartRateRecoveryActivityDuration",
      "HKMetadataKeyHeartRateRecoveryActivityDuration"),
    kept(
      "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate",
      "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate"),
    kept("HKMetadataKeyVO2MaxTestType", "HKVO2MaxTestType"),
    kept("HKMetadataKeyVO2MaxValue", "HKVO2MaxValue"),
    kept("HKMetadataKeyLowCardioFitnessEventThreshold", "HKLowCardioFitnessEventThreshold"),
    // Hearing
    kept("HKMetadataKeyAudioExposureLevel", "HKMetadataKeyAudioExposureLevel"),
    kept("HKMetadataKeyAudioExposureDuration", "HKMetadataKeyAudioExposureDuration"),
    kept("HKMetadataKeyHeadphoneGain", "HKMetadataKeyHeadphoneGain"),
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
    kept("HKMetadataKeyElevationAscended", "HKElevationAscended"),
    kept("HKMetadataKeyElevationDescended", "HKElevationDescended"),
    kept("HKMetadataKeyAverageSpeed", "HKAverageSpeed"),
    kept("HKMetadataKeyMaximumSpeed", "HKMaximumSpeed"),
    kept("HKMetadataKeyAverageMETs", "HKAverageMETs"),
    kept("HKMetadataKeyLapLength", "HKLapLength"),
    kept("HKMetadataKeySwimmingStrokeStyle", "HKSwimmingStrokeStyle"),
    kept("HKMetadataKeySWOLFScore", "HKSWOLFScore"),
    kept("HKMetadataKeyAlpineSlopeGrade", "HKAlpineSlopeGrade"),
    kept("HKMetadataKeyWeatherCondition", "HKWeatherCondition"),
    kept("HKMetadataKeyWeatherTemperature", "HKWeatherTemperature"),
    kept("HKMetadataKeyWeatherHumidity", "HKWeatherHumidity"),
    kept("HKMetadataKeyCoachedWorkout", "HKCoachedWorkout"),
    kept("HKMetadataKeyGroupFitness", "HKGroupFitness"),
    kept("HKMetadataKeyAppleFitnessPlusSession", "HKMetadataKeyAppleFitnessPlusSession"),
    dropped(
      "HKMetadataKeyAppleFitnessPlusCatalogIdentifier",
      "HKMetadataKeyAppleFitnessPlusCatalogIdentifier"),
    kept("HKMetadataKeyCrossTrainerDistance", "HKCrossTrainerDistance"),
    kept("HKMetadataKeyIndoorBikeDistance", "HKIndoorBikeDistance"),
    kept("HKMetadataKeyFitnessMachineDuration", "HKFitnessMachineDuration"),
    kept(
      "HKMetadataKeyCyclingFunctionalThresholdPowerTestType",
      "HKCyclingCyclingFunctionalThresholdPowerTestType"),
  ]

  /// Keys that aren't HealthKit's but are kept: lil health's own, the WorkoutKit plan the
  /// iPhone adds to a workout's metadata (`HealthEncoder.workoutPlanKey`, 851-4030), and the
  /// noise notifications' level and duration under the names the Mac reads them by
  /// (`NotificationQueries`), until it reads HealthKit's (the 2026-11-09 sync audit's item 3).
  static let otherKeptMetadataKeys = [
    "LilWorkoutPlan", "HKAudioExposureLevel", "HKAudioExposureDuration",
  ]

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

  private static func kept(_ constant: String, _ key: String) -> HealthMetadataKey {
    HealthMetadataKey(constant: constant, key: key, kept: true)
  }

  private static func dropped(_ constant: String, _ key: String) -> HealthMetadataKey {
    HealthMetadataKey(constant: constant, key: key, kept: false)
  }
}
