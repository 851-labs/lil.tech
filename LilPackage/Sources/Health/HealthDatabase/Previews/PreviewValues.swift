import Foundation
import HealthCatalog

/// What a type's synthetic values look like in the preview database (851-3115), so catalogs' numbers,
/// axes and units read as one person's would: a height of 175 cm, not 353 m. In the catalog's units
/// (`HealthDataType.unit`): metres, kilograms, and percentages as fractions (0.22 is 22 %).
enum PreviewValues: Equatable {
  /// Readings in a band, one person's: a line's (weight, resting heart rate) drift through it from
  /// day to day, dots and ranges scatter across it.
  case readings(ClosedRange<Double>)
  /// A cumulative type's total for a day from 7:00 to 23:00, spread over every half-hour, or over
  /// `sessions` of them (meals, workouts).
  case daily(ClosedRange<Double>, sessions: Int? = nil)

  static func of(_ type: HealthDataType) -> PreviewValues {
    let name = type.id.components(separatedBy: "Identifier").last ?? type.id
    if let values = byType[name] { return values }
    // A type added to the catalog since, until it gets its own.
    if type.aggregation?.isCumulative == true { return .daily(5...15, sessions: 3) }
    return switch type.unit {
    case "%": .readings(0.9...0.99)
    case "count/min": .readings(60...100)
    case "degC": .readings(36.3...37.1)
    case "dBASPL": .readings(50...80)
    case "m/s": .readings(1...1.5)
    case "ms": .readings(30...80)
    default: .readings(1...10)
    }
  }

  /// Each quantity type's, by the end of its identifier. Cumulative types' totals for a day.
  private static let byType: [String: PreviewValues] = [
    // Activity.
    "StepCount": .daily(6_000...10_000),
    "DistanceWalkingRunning": .daily(4_500...7_500),
    "ActiveEnergyBurned": .daily(400...700),
    "BasalEnergyBurned": .daily(1_500...1_650),
    "AppleExerciseTime": .daily(25...60, sessions: 4),
    "AppleMoveTime": .daily(30...60, sessions: 4),
    "AppleStandTime": .daily(150...240),
    "FlightsClimbed": .daily(6...16),
    "PushCount": .daily(800...1_500),
    "DistanceWheelchair": .daily(1_500...3_000),
    "DistanceCycling": .daily(8_000...15_000, sessions: 2),
    "CyclingCadence": .readings(70...95),
    "CyclingFunctionalThresholdPower": .readings(205...225),
    "CyclingPower": .readings(120...230),
    "CyclingSpeed": .readings(5.5...8.5),
    "DistanceSwimming": .daily(1_000...1_800, sessions: 2),
    "SwimmingStrokeCount": .daily(600...1_000, sessions: 2),
    "DistanceDownhillSnowSports": .daily(10_000...20_000, sessions: 4),
    "DistanceCrossCountrySkiing": .daily(8_000...15_000, sessions: 3),
    "CrossCountrySkiingSpeed": .readings(2...4),
    "DistancePaddleSports": .daily(3_000...6_000, sessions: 2),
    "PaddleSportsSpeed": .readings(1.2...2),
    "DistanceRowing": .daily(4_000...8_000, sessions: 2),
    "RowingSpeed": .readings(2.5...4),
    "DistanceSkatingSports": .daily(3_000...6_000, sessions: 2),
    "RunningPower": .readings(200...290),
    "RunningSpeed": .readings(2.6...3.4),
    "PhysicalEffort": .readings(1.5...8),
    "WorkoutEffortScore": .readings(3...8),
    "EstimatedWorkoutEffortScore": .readings(3...8),
    "NikeFuel": .daily(1_500...3_000),
    // Body measurements: about 175 cm and 70 kg, so a BMI about 23.
    "BodyMass": .readings(69...72),
    "Height": .readings(1.745...1.755),
    "BodyMassIndex": .readings(22.5...23.5),
    "BodyFatPercentage": .readings(0.21...0.24),
    "LeanBodyMass": .readings(53.5...55.5),
    "WaistCircumference": .readings(0.8...0.84),
    "AppleSleepingWristTemperature": .readings(35.2...35.8),
    "ElectrodermalActivity": .readings(2...8),
    // Cycle tracking.
    "BasalBodyTemperature": .readings(36.2...36.8),
    // Hearing.
    "EnvironmentalAudioExposure": .readings(50...85),
    "HeadphoneAudioExposure": .readings(55...80),
    "EnvironmentalSoundReduction": .readings(15...30),
    // Heart.
    "HeartRate": .readings(56...110),
    "RestingHeartRate": .readings(56...62),
    "WalkingHeartRateAverage": .readings(95...108),
    "HeartRateVariabilitySDNN": .readings(30...80),
    "HeartRateVariabilityRMSSD": .readings(25...70),
    "HeartRateRecoveryOneMinute": .readings(22...32),
    "VO2Max": .readings(38...42),
    "AtrialFibrillationBurden": .readings(0.01...0.03),
    "BloodPressureSystolic": .readings(112...128),
    "BloodPressureDiastolic": .readings(70...84),
    // Mental wellbeing.
    "TimeInDaylight": .daily(30...120, sessions: 6),
    // Mobility.
    "WalkingSpeed": .readings(1.1...1.5),
    "WalkingStepLength": .readings(0.68...0.76),
    "WalkingAsymmetryPercentage": .readings(0.01...0.08),
    "WalkingDoubleSupportPercentage": .readings(0.24...0.32),
    "AppleWalkingSteadiness": .readings(0.85...0.98),
    "SixMinuteWalkTestDistance": .readings(480...560),
    "StairAscentSpeed": .readings(0.35...0.55),
    "StairDescentSpeed": .readings(0.4...0.6),
    "RunningStrideLength": .readings(1.1...1.3),
    "RunningGroundContactTime": .readings(230...280),
    "RunningVerticalOscillation": .readings(8...10),
    // Nutrition: a day's meals, about what's recommended.
    "DietaryEnergyConsumed": .daily(1_800...2_400, sessions: 4),
    "DietaryWater": .daily(1_500...2_500, sessions: 8),
    "DietaryCaffeine": .daily(100...300, sessions: 3),
    "DietaryCarbohydrates": .daily(200...300, sessions: 4),
    "DietaryFiber": .daily(20...35, sessions: 4),
    "DietarySugar": .daily(30...70, sessions: 4),
    "DietaryProtein": .daily(60...110, sessions: 4),
    "DietaryFatTotal": .daily(60...90, sessions: 4),
    "DietaryFatSaturated": .daily(15...25, sessions: 4),
    "DietaryFatMonounsaturated": .daily(20...35, sessions: 4),
    "DietaryFatPolyunsaturated": .daily(10...20, sessions: 4),
    "DietaryCholesterol": .daily(150...300, sessions: 4),
    "DietarySodium": .daily(1_800...3_000, sessions: 4),
    "DietaryPotassium": .daily(2_500...3_500, sessions: 4),
    "DietaryCalcium": .daily(800...1_200, sessions: 4),
    "DietaryChloride": .daily(2_500...3_500, sessions: 4),
    "DietaryIron": .daily(10...18, sessions: 4),
    "DietaryMagnesium": .daily(250...400, sessions: 4),
    "DietaryManganese": .daily(2...4, sessions: 4),
    "DietaryPhosphorus": .daily(900...1_400, sessions: 4),
    "DietaryZinc": .daily(8...12, sessions: 4),
    "DietaryCopper": .daily(0.8...1.5, sessions: 4),
    "DietaryChromium": .daily(25...45, sessions: 4),
    "DietaryIodine": .daily(120...180, sessions: 4),
    "DietaryMolybdenum": .daily(40...60, sessions: 4),
    "DietarySelenium": .daily(50...80, sessions: 4),
    "DietaryVitaminA": .daily(600...900, sessions: 4),
    "DietaryThiamin": .daily(1...1.5, sessions: 4),
    "DietaryRiboflavin": .daily(1.1...1.6, sessions: 4),
    "DietaryNiacin": .daily(14...20, sessions: 4),
    "DietaryPantothenicAcid": .daily(4...6, sessions: 4),
    "DietaryVitaminB6": .daily(1.3...2, sessions: 4),
    "DietaryBiotin": .daily(25...40, sessions: 4),
    "DietaryFolate": .daily(300...450, sessions: 4),
    "DietaryVitaminB12": .daily(2...5, sessions: 4),
    "DietaryVitaminC": .daily(60...120, sessions: 4),
    "DietaryVitaminD": .daily(5...15, sessions: 4),
    "DietaryVitaminE": .daily(10...15, sessions: 4),
    "DietaryVitaminK": .daily(80...150, sessions: 4),
    // Respiratory.
    "RespiratoryRate": .readings(12...18),
    "OxygenSaturation": .readings(0.95...0.99),
    "AppleSleepingBreathingDisturbances": .readings(1...4),
    "ForcedVitalCapacity": .readings(4...4.4),
    "ForcedExpiratoryVolume1": .readings(3.2...3.5),
    "PeakExpiratoryFlowRate": .readings(430...480),
    "InhalerUsage": .daily(1...3),
    // Vitals.
    "BodyTemperature": .readings(36.4...37),
    "BloodGlucose": .readings(80...130),
    // Other data: blood alcohol as a fraction too, 0.02–0.06 %.
    "BloodAlcoholContent": .readings(0.0002...0.0006),
    "NumberOfAlcoholicBeverages": .daily(0...2),
    "InsulinDelivery": .daily(30...45, sessions: 6),
    // A fall every week or so.
    "NumberOfTimesFallen": .daily(0...0.6),
    "PeripheralPerfusionIndex": .readings(0.01...0.05),
    "UVExposure": .readings(1...7),
    "UnderwaterDepth": .readings(2...12),
    "WaterTemperature": .readings(18...26),
  ]
}
