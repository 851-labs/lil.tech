extension HealthMetadataKey {
  /// A HealthKit metadata key lil health's code reads by name (851-4168), by the value HealthKit
  /// puts in `metadata`, which isn't always its constant's name: `HKMetadataKeyIndoorWorkout` is
  /// `HKIndoorWorkout`, but `HKMetadataKeyAudioExposureLevel` is itself. The Mac read noise
  /// notifications under names HealthKit never writes until 851-4148, and the tests and catalog
  /// repeated them, so every test passed.
  ///
  /// Each case is named for its constant (`HKMetadataKey` and the case's name, in any case), and
  /// `MetadataKeyNameTests` checks every case against the allow-list and HealthKit's constant of
  /// that name, so a key read here is always the SDK's. A key the code reads joins this list; the
  /// server's are typed by its table's keys (`MetadataKey`, `Services/api/src/health/MetadataValues.ts`).
  public enum Name: String, CaseIterable, Sendable {
    // Every object
    case timeZone = "HKTimeZone"
    case wasUserEntered = "HKWasUserEntered"
    // The device
    case deviceName = "HKDeviceName"
    case deviceManufacturerName = "HKDeviceManufacturerName"
    case appleDeviceCalibrated = "HKMetadataKeyAppleDeviceCalibrated"
    case devicePlacementSide = "HKMetadataKeyDevicePlacementSide"
    // Estimates and measurements
    case algorithmVersion = "HKAlgorithmVersion"
    case appleECGAlgorithmVersion = "HKMetadataKeyAppleECGAlgorithmVersion"
    case dateOfEarliestDataUsedForEstimate = "HKDateOfEarliestDataUsedForEstimate"
    case quantityClampedToLowerBound = "HKMetadataKeyQuantityClampedToLowerBound"
    case quantityClampedToUpperBound = "HKMetadataKeyQuantityClampedToUpperBound"
    case referenceRangeLowerLimit = "HKReferenceRangeLowerLimit"
    case referenceRangeUpperLimit = "HKReferenceRangeUpperLimit"
    case wasTakenInLab = "HKWasTakenInLab"
    case userMotionContext = "HKMetadataKeyUserMotionContext"
    case waterSalinity = "HKMetadataKeyWaterSalinity"
    case maximumLightIntensity = "HKMetadataKeyMaximumLightIntensity"
    case physicalEffortEstimationType = "HKPhysicalEffortEstimationType"
    case activityType = "HKActivityType"
    // Heart
    case heartRateMotionContext = "HKMetadataKeyHeartRateMotionContext"
    case heartRateSensorLocation = "HKHeartRateSensorLocation"
    case heartRateEventThreshold = "HKHeartRateEventThreshold"
    case heartRateRecoveryTestType = "HKMetadataKeyHeartRateRecoveryTestType"
    case heartRateRecoveryActivityType = "HKMetadataKeyHeartRateRecoveryActivityType"
    case heartRateRecoveryActivityDuration = "HKMetadataKeyHeartRateRecoveryActivityDuration"
    case heartRateRecoveryMaxObservedRecoveryHeartRate =
      "HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate"
    case vo2MaxTestType = "HKVO2MaxTestType"
    case vo2MaxValue = "HKVO2MaxValue"
    case lowCardioFitnessEventThreshold = "HKLowCardioFitnessEventThreshold"
    // Hearing
    case audioExposureLevel = "HKMetadataKeyAudioExposureLevel"
    case audioExposureDuration = "HKMetadataKeyAudioExposureDuration"
    case headphoneGain = "HKMetadataKeyHeadphoneGain"
    // Clinical, cycle tracking and nutrition
    case bloodGlucoseMealTime = "HKBloodGlucoseMealTime"
    case insulinDeliveryReason = "HKInsulinDeliveryReason"
    case bodyTemperatureSensorLocation = "HKBodyTemperatureSensorLocation"
    case menstrualCycleStart = "HKMenstrualCycleStart"
    case sexualActivityProtectionUsed = "HKSexualActivityProtectionUsed"
    case foodType = "HKFoodType"
    // Workouts
    case indoorWorkout = "HKIndoorWorkout"
    case swimmingLocationType = "HKSwimmingLocationType"
    case workoutBrandName = "HKWorkoutBrandName"
    case elevationAscended = "HKElevationAscended"
    case elevationDescended = "HKElevationDescended"
    case averageSpeed = "HKAverageSpeed"
    case maximumSpeed = "HKMaximumSpeed"
    case averageMETs = "HKAverageMETs"
    case lapLength = "HKLapLength"
    case swimmingStrokeStyle = "HKSwimmingStrokeStyle"
    case swolfScore = "HKSWOLFScore"
    case weatherCondition = "HKWeatherCondition"
    case weatherTemperature = "HKWeatherTemperature"
    case weatherHumidity = "HKWeatherHumidity"
    case crossTrainerDistance = "HKCrossTrainerDistance"
    case indoorBikeDistance = "HKIndoorBikeDistance"
  }
}

extension Dictionary where Key == String {
  /// The value at a HealthKit metadata key.
  public subscript(key: HealthMetadataKey.Name) -> Value? {
    self[key.rawValue]
  }
}

extension HealthMetadataValues {
  /// What `metadata` says at `key`, read as the key's kind (`kinds`), or nil if it doesn't say.
  public static func value(_ key: HealthMetadataKey.Name, in metadata: [String: Any]?) -> Value? {
    value(key.rawValue, in: metadata)
  }
}
