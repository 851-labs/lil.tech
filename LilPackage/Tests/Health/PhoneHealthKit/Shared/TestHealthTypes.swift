import HealthKit

/// The types the iPhone's HealthKit tests write and read (`HealthKitPhoneTests`), which their host
/// asks to share and read once, when `GrantHealthAccess` launches it (851-3199). Add a type here
/// before a test writes it.
enum TestHealthTypes {
  static let quantities: [HKQuantityTypeIdentifier] = [
    .stepCount, .activeEnergyBurned, .distanceWalkingRunning, .heartRate, .restingHeartRate,
    .bodyMass, .bodyTemperature, .heartRateVariabilitySDNN, .environmentalAudioExposure,
  ]

  static var all: Set<HKSampleType> {
    var types = Set<HKSampleType>(quantities.map { HKQuantityType($0) })
    // For event windows (851-3200).
    types.insert(HKCategoryType(.sleepAnalysis))
    types.insert(HKWorkoutType.workoutType())
    return types
  }
}
