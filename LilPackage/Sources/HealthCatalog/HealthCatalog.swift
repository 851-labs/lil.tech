/// Every Apple Health data type lil health syncs.
///
/// HealthKit has no API that lists its types, so this list is maintained by hand.
/// `HealthCatalogTests` checks it against the SDK's headers and HealthKit itself: every
/// identifier is covered, and units, aggregation styles and availability match.
public enum HealthCatalog {
  public static let all: [HealthDataType] =
    activity + bodyMeasurements + cycleTracking + hearing + heart + medications
    + mentalWellbeing + mobility + nutrition + respiratory + sleep + symptoms + vitals
    + otherData + characteristics

  private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

  private static let byCategory = Dictionary(
    grouping: all.flatMap { type in
      ([type.category].compactMap(\.self) + type.alsoListedIn).map { ($0, type) }
    },
    by: \.0
  )
  .mapValues { $0.map(\.1) }

  public static func type(id: String) -> HealthDataType? {
    byID[id]
  }

  /// Types Browse lists under a category, including types whose own screen is elsewhere.
  public static func types(in category: HealthCategory) -> [HealthDataType] {
    byCategory[category] ?? []
  }

  /// Types that exist on a given iOS version.
  public static func types(availableOn version: IOSVersion) -> [HealthDataType] {
    all.filter { $0.introduced <= version }
  }

  /// Types to pass to `requestAuthorization(toShare:read:)` on a given iOS version. Per-object
  /// types are requested separately, and the rest can't be requested.
  public static func standardReadTypes(availableOn version: IOSVersion) -> [HealthDataType] {
    types(availableOn: version).filter { $0.readAuthorization == .standard }
  }
}

// MARK: - Categories

extension HealthCatalog {
  static let activity: [HealthDataType] = [
    quantity("StepCount", "Steps", .activity, "count", .cumulative, .ios(8)),
    quantity(
      "DistanceWalkingRunning", "Walking + Running Distance", .activity, "m", .cumulative, .ios(8)
    ),
    quantity("ActiveEnergyBurned", "Active Energy", .activity, "kcal", .cumulative, .ios(8)),
    quantity("BasalEnergyBurned", "Resting Energy", .activity, "kcal", .cumulative, .ios(8)),
    quantity("AppleExerciseTime", "Exercise Minutes", .activity, "min", .cumulative, .ios(9, 3)),
    quantity("AppleMoveTime", "Move Minutes", .activity, "min", .cumulative, .ios(14, 5)),
    quantity("AppleStandTime", "Stand Minutes", .activity, "min", .cumulative, .ios(13)),
    category("AppleStandHour", "Stand Hours", .activity, .ios(9)),
    quantity("FlightsClimbed", "Flights Climbed", .activity, "count", .cumulative, .ios(8)),
    quantity("PushCount", "Pushes", .activity, "count", .cumulative, .ios(10)),
    quantity("DistanceWheelchair", "Wheelchair Distance", .activity, "m", .cumulative, .ios(10)),
    quantity("DistanceCycling", "Cycling Distance", .activity, "m", .cumulative, .ios(8)),
    quantity(
      "CyclingCadence", "Cycling Cadence", .activity, "count/min", .discreteTemporallyWeighted,
      .ios(17)
    ),
    quantity(
      "CyclingFunctionalThresholdPower", "Cycling Functional Threshold Power", .activity, "W",
      .discreteArithmetic, .ios(17)
    ),
    quantity(
      "CyclingPower", "Cycling Power", .activity, "W", .discreteTemporallyWeighted, .ios(17)
    ),
    quantity(
      "CyclingSpeed", "Cycling Speed", .activity, "m/s", .discreteTemporallyWeighted, .ios(17)
    ),
    quantity("DistanceSwimming", "Swimming Distance", .activity, "m", .cumulative, .ios(10)),
    quantity("SwimmingStrokeCount", "Swimming Strokes", .activity, "count", .cumulative, .ios(10)),
    quantity(
      "DistanceDownhillSnowSports", "Downhill Snow Sports Distance", .activity, "m", .cumulative,
      .ios(11, 2)
    ),
    quantity(
      "DistanceCrossCountrySkiing", "Cross-Country Skiing Distance", .activity, "m", .cumulative,
      .ios(18)
    ),
    quantity(
      "CrossCountrySkiingSpeed", "Cross-Country Skiing Speed", .activity, "m/s",
      .discreteArithmetic, .ios(18)
    ),
    quantity(
      "DistancePaddleSports", "Paddle Sports Distance", .activity, "m", .cumulative, .ios(18)
    ),
    quantity(
      "PaddleSportsSpeed", "Paddle Sports Speed", .activity, "m/s", .discreteArithmetic, .ios(18)
    ),
    quantity("DistanceRowing", "Rowing Distance", .activity, "m", .cumulative, .ios(18)),
    quantity("RowingSpeed", "Rowing Speed", .activity, "m/s", .discreteArithmetic, .ios(18)),
    quantity(
      "DistanceSkatingSports", "Skating Sports Distance", .activity, "m", .cumulative, .ios(18)
    ),
    quantity("RunningPower", "Running Power", .activity, "W", .discreteArithmetic, .ios(16)),
    quantity("RunningSpeed", "Running Speed", .activity, "m/s", .discreteArithmetic, .ios(16)),
    quantity(
      "PhysicalEffort", "Physical Effort", .activity, "kcal/(kg*hr)", .discreteArithmetic, .ios(17)
    ),
    quantity(
      "WorkoutEffortScore", "Workout Effort", .activity, "appleEffortScore", .discreteArithmetic,
      .ios(18)
    ),
    quantity(
      "EstimatedWorkoutEffortScore", "Estimated Workout Effort", .activity, "appleEffortScore",
      .discreteArithmetic, .ios(18)
    ),
    // HealthKit refuses third-party reads of NikeFuel. Not confirmed on a device: 851-2607's check
    // couldn't find it in Health's list of what lil health reads, which has no search.
    quantity(
      "NikeFuel", "NikeFuel", .activity, "count", .cumulative, .ios(8),
      readAuthorization: .unavailable
    ),
    special("HKWorkoutTypeIdentifier", .workout, "Workouts", .activity, .ios(8)),
    special("HKWorkoutRouteTypeIdentifier", .workoutRoute, "Workout Routes", .activity, .ios(11)),
    special(
      "HKActivitySummaryTypeIdentifier", .activitySummary, "Activity Rings", .activity, .ios(9, 3)
    ),
  ]

  static let bodyMeasurements: [HealthDataType] = [
    quantity("BodyMass", "Weight", .bodyMeasurements, "kg", .discreteArithmetic, .ios(8)),
    quantity("Height", "Height", .bodyMeasurements, "m", .discreteArithmetic, .ios(8)),
    quantity(
      "BodyMassIndex", "Body Mass Index", .bodyMeasurements, "count", .discreteArithmetic, .ios(8)
    ),
    quantity(
      "BodyFatPercentage", "Body Fat Percentage", .bodyMeasurements, "%", .discreteArithmetic,
      .ios(8)
    ),
    quantity(
      "LeanBodyMass", "Lean Body Mass", .bodyMeasurements, "kg", .discreteArithmetic, .ios(8)),
    quantity(
      "WaistCircumference", "Waist Circumference", .bodyMeasurements, "m", .discreteArithmetic,
      .ios(11)
    ),
    quantity(
      "AppleSleepingWristTemperature", "Wrist Temperature", .bodyMeasurements, "degC",
      .discreteArithmetic, .ios(16), alsoListedIn: [.vitals]
    ),
    quantity(
      "ElectrodermalActivity", "Electrodermal Activity", .bodyMeasurements, "mcS",
      .discreteArithmetic, .ios(8)
    ),
  ]

  static let cycleTracking: [HealthDataType] = [
    category("MenstrualFlow", "Period", .cycleTracking, .ios(9)),
    quantity(
      "BasalBodyTemperature", "Basal Body Temperature", .cycleTracking, "degC",
      .discreteArithmetic, .ios(9)
    ),
    category("CervicalMucusQuality", "Cervical Mucus Quality", .cycleTracking, .ios(9)),
    category("OvulationTestResult", "Ovulation Test Result", .cycleTracking, .ios(9)),
    category("PregnancyTestResult", "Pregnancy Test Result", .cycleTracking, .ios(15)),
    category("ProgesteroneTestResult", "Progesterone Test Result", .cycleTracking, .ios(15)),
    category("IntermenstrualBleeding", "Spotting", .cycleTracking, .ios(9)),
    category("SexualActivity", "Sexual Activity", .cycleTracking, .ios(9)),
    category("Contraceptive", "Contraceptives", .cycleTracking, .ios(14, 3)),
    category("Lactation", "Lactation", .cycleTracking, .ios(14, 3)),
    category("Pregnancy", "Pregnancy", .cycleTracking, .ios(14, 3)),
    category("BleedingDuringPregnancy", "Bleeding During Pregnancy", .cycleTracking, .ios(18)),
    category("BleedingAfterPregnancy", "Bleeding After Pregnancy", .cycleTracking, .ios(18)),
    category("BleedingAfterMenopause", "Bleeding After Menopause", .cycleTracking, .ios(27)),
    category("MenopausalState", "Menopause", .cycleTracking, .ios(27)),
    category("InfrequentMenstrualCycles", "Infrequent Periods", .cycleTracking, .ios(16)),
    category("IrregularMenstrualCycles", "Irregular Cycles", .cycleTracking, .ios(16)),
    category(
      "PersistentIntermenstrualBleeding", "Persistent Spotting", .cycleTracking, .ios(16)
    ),
    category("ProlongedMenstrualPeriods", "Prolonged Periods", .cycleTracking, .ios(16)),
  ]

  static let hearing: [HealthDataType] = [
    quantity(
      "EnvironmentalAudioExposure", "Environmental Sound Levels", .hearing, "dBASPL",
      .discreteEquivalentContinuousLevel, .ios(13)
    ),
    quantity(
      "HeadphoneAudioExposure", "Headphone Audio Levels", .hearing, "dBASPL",
      .discreteEquivalentContinuousLevel, .ios(13)
    ),
    quantity(
      "EnvironmentalSoundReduction", "Environmental Sound Reduction", .hearing, "dBASPL",
      .discreteEquivalentContinuousLevel, .ios(16)
    ),
    // `HKCategoryTypeIdentifierEnvironmentalAudioExposureEvent`'s value is still the name of
    // the identifier it replaced.
    special(
      "HKCategoryTypeIdentifierAudioExposureEvent", .category, "Noise Notifications", .hearing,
      .ios(14)),
    category(
      "HeadphoneAudioExposureEvent", "Headphone Notifications", .hearing, .ios(14, 2)
    ),
    special("HKDataTypeIdentifierAudiogram", .audiogram, "Audiograms", .hearing, .ios(13)),
  ]

  static let heart: [HealthDataType] = [
    quantity(
      "HeartRate", "Heart Rate", .heart, "count/min", .discreteTemporallyWeighted, .ios(8),
      alsoListedIn: [.vitals]
    ),
    quantity(
      "RestingHeartRate", "Resting Heart Rate", .heart, "count/min", .discreteTemporallyWeighted,
      .ios(11)
    ),
    quantity(
      "WalkingHeartRateAverage", "Walking Heart Rate Average", .heart, "count/min",
      .discreteTemporallyWeighted, .ios(11)
    ),
    quantity(
      "HeartRateVariabilitySDNN", "Heart Rate Variability", .heart, "ms", .discreteArithmetic,
      .ios(11)
    ),
    quantity(
      "HeartRateVariabilityRMSSD", "Heart Rate Variability (RMSSD)", .heart, "ms",
      .discreteArithmetic, .ios(27)
    ),
    quantity(
      "HeartRateRecoveryOneMinute", "Cardio Recovery", .heart, "count/min", .discreteArithmetic,
      .ios(16)
    ),
    quantity("VO2Max", "Cardio Fitness", .heart, "ml/(kg*min)", .discreteArithmetic, .ios(11)),
    quantity(
      "AtrialFibrillationBurden", "AFib History", .heart, "%", .discreteTemporallyWeighted, .ios(16)
    ),
    correlation("BloodPressure", "Blood Pressure", .heart, .ios(8), alsoListedIn: [.vitals]),
    quantity(
      "BloodPressureSystolic", "Systolic Blood Pressure", .heart, "mmHg", .discreteArithmetic,
      .ios(8)
    ),
    quantity(
      "BloodPressureDiastolic", "Diastolic Blood Pressure", .heart, "mmHg", .discreteArithmetic,
      .ios(8)
    ),
    category("HighHeartRateEvent", "High Heart Rate Notifications", .heart, .ios(12, 2)),
    category("LowHeartRateEvent", "Low Heart Rate Notifications", .heart, .ios(12, 2)),
    category(
      "IrregularHeartRhythmEvent", "Irregular Rhythm Notifications", .heart, .ios(12, 2)
    ),
    category("LowCardioFitnessEvent", "Low Cardio Fitness Notifications", .heart, .ios(14, 3)),
    category("HypertensionEvent", "Hypertension Notifications", .heart, .ios(26, 2)),
    special("HKDataTypeIdentifierElectrocardiogram", .electrocardiogram, "ECG", .heart, .ios(14)),
    special(
      "HKDataTypeIdentifierHeartbeatSeries", .heartbeatSeries, "Heartbeat Series", .heart, .ios(13)
    ),
  ]

  static let medications: [HealthDataType] = [
    special(
      "HKDataTypeUserAnnotatedMedicationConcept", .medication, "Medications", .medications,
      .ios(26), readAuthorization: .perObject
    ),
    special(
      // Dose events come with the medications the user shares per object: on a device (851-2607),
      // Health's picker lists medications, current and archived, with no switch of their own for
      // doses. Reading them is checked with medications' sync (851-2571).
      "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent", .medicationDoseEvent,
      "Medication Doses", .medications, .ios(26), readAuthorization: .perObject
    ),
  ]

  static let mentalWellbeing: [HealthDataType] = [
    special("HKDataTypeStateOfMind", .stateOfMind, "State of Mind", .mentalWellbeing, .ios(18)),
    category("MindfulSession", "Mindful Minutes", .mentalWellbeing, .ios(10)),
    quantity(
      "TimeInDaylight", "Time in Daylight", .mentalWellbeing, "min", .cumulative, .ios(17)
    ),
    special(
      "HKScoredAssessmentTypeIdentifierGAD7", .scoredAssessment, "Anxiety Risk (GAD-7)",
      .mentalWellbeing, .ios(18)
    ),
    special(
      "HKScoredAssessmentTypeIdentifierPHQ9", .scoredAssessment, "Depression Risk (PHQ-9)",
      .mentalWellbeing, .ios(18)
    ),
  ]

  static let mobility: [HealthDataType] = [
    quantity("WalkingSpeed", "Walking Speed", .mobility, "m/s", .discreteArithmetic, .ios(14)),
    quantity(
      "WalkingStepLength", "Walking Step Length", .mobility, "m", .discreteArithmetic, .ios(14)),
    quantity(
      "WalkingAsymmetryPercentage", "Walking Asymmetry", .mobility, "%", .discreteArithmetic,
      .ios(14)
    ),
    quantity(
      "WalkingDoubleSupportPercentage", "Double Support Time", .mobility, "%", .discreteArithmetic,
      .ios(14)
    ),
    quantity(
      "AppleWalkingSteadiness", "Walking Steadiness", .mobility, "%", .discreteArithmetic, .ios(15)
    ),
    category(
      "AppleWalkingSteadinessEvent", "Walking Steadiness Notifications", .mobility, .ios(15)
    ),
    quantity(
      "SixMinuteWalkTestDistance", "Six-Minute Walk", .mobility, "m", .discreteArithmetic, .ios(14)
    ),
    quantity(
      "StairAscentSpeed", "Stair Speed: Up", .mobility, "m/s", .discreteArithmetic, .ios(14)),
    quantity(
      "StairDescentSpeed", "Stair Speed: Down", .mobility, "m/s", .discreteArithmetic, .ios(14)
    ),
    quantity(
      "RunningStrideLength", "Running Stride Length", .mobility, "m", .discreteArithmetic, .ios(16)
    ),
    quantity(
      "RunningGroundContactTime", "Ground Contact Time", .mobility, "ms", .discreteArithmetic,
      .ios(16)
    ),
    quantity(
      "RunningVerticalOscillation", "Vertical Oscillation", .mobility, "cm", .discreteArithmetic,
      .ios(16)
    ),
  ]

  static let nutrition: [HealthDataType] = [
    correlation("Food", "Food", .nutrition, .ios(8)),
    quantity("DietaryEnergyConsumed", "Dietary Energy", .nutrition, "kcal", .cumulative, .ios(8)),
    quantity("DietaryWater", "Water", .nutrition, "mL", .cumulative, .ios(9)),
    quantity("DietaryCaffeine", "Caffeine", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryCarbohydrates", "Carbohydrates", .nutrition, "g", .cumulative, .ios(8)),
    quantity("DietaryFiber", "Fiber", .nutrition, "g", .cumulative, .ios(8)),
    quantity("DietarySugar", "Dietary Sugar", .nutrition, "g", .cumulative, .ios(8)),
    quantity("DietaryProtein", "Protein", .nutrition, "g", .cumulative, .ios(8)),
    quantity("DietaryFatTotal", "Total Fat", .nutrition, "g", .cumulative, .ios(8)),
    quantity("DietaryFatSaturated", "Saturated Fat", .nutrition, "g", .cumulative, .ios(8)),
    quantity(
      "DietaryFatMonounsaturated", "Monounsaturated Fat", .nutrition, "g", .cumulative, .ios(8)
    ),
    quantity(
      "DietaryFatPolyunsaturated", "Polyunsaturated Fat", .nutrition, "g", .cumulative, .ios(8)
    ),
    quantity("DietaryCholesterol", "Dietary Cholesterol", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietarySodium", "Sodium", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryPotassium", "Potassium", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryCalcium", "Calcium", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryChloride", "Chloride", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryIron", "Iron", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryMagnesium", "Magnesium", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryManganese", "Manganese", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryPhosphorus", "Phosphorus", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryZinc", "Zinc", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryCopper", "Copper", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryChromium", "Chromium", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryIodine", "Iodine", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryMolybdenum", "Molybdenum", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietarySelenium", "Selenium", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryVitaminA", "Vitamin A", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryThiamin", "Thiamin", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryRiboflavin", "Riboflavin", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryNiacin", "Niacin", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryPantothenicAcid", "Pantothenic Acid", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryVitaminB6", "Vitamin B6", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryBiotin", "Biotin", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryFolate", "Folate", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryVitaminB12", "Vitamin B12", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryVitaminC", "Vitamin C", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryVitaminD", "Vitamin D", .nutrition, "mcg", .cumulative, .ios(8)),
    quantity("DietaryVitaminE", "Vitamin E", .nutrition, "mg", .cumulative, .ios(8)),
    quantity("DietaryVitaminK", "Vitamin K", .nutrition, "mcg", .cumulative, .ios(8)),
  ]

  static let respiratory: [HealthDataType] = [
    quantity(
      "RespiratoryRate", "Respiratory Rate", .respiratory, "count/min", .discreteArithmetic,
      .ios(8), alsoListedIn: [.vitals]
    ),
    quantity(
      "OxygenSaturation", "Blood Oxygen", .respiratory, "%", .discreteArithmetic, .ios(8),
      alsoListedIn: [.vitals]
    ),
    quantity(
      "AppleSleepingBreathingDisturbances", "Breathing Disturbances", .respiratory, "count",
      .discreteArithmetic, .ios(18)
    ),
    category("SleepApneaEvent", "Sleep Apnea Notifications", .respiratory, .ios(18)),
    quantity(
      "ForcedVitalCapacity", "Forced Vital Capacity", .respiratory, "L", .discreteArithmetic,
      .ios(8)
    ),
    quantity(
      "ForcedExpiratoryVolume1", "Forced Expiratory Volume, 1 sec", .respiratory, "L",
      .discreteArithmetic, .ios(8)
    ),
    quantity(
      "PeakExpiratoryFlowRate", "Peak Expiratory Flow Rate", .respiratory, "L/min",
      .discreteArithmetic, .ios(8)
    ),
    quantity("InhalerUsage", "Inhaler Usage", .respiratory, "count", .cumulative, .ios(8)),
  ]

  static let sleep: [HealthDataType] = [
    category("SleepAnalysis", "Sleep", .sleep, .ios(8))
  ]

  static let symptoms: [HealthDataType] = [
    category("AbdominalCramps", "Abdominal Cramps", .symptoms, .ios(13, 6)),
    category("Acne", "Acne", .symptoms, .ios(13, 6)),
    category("AppetiteChanges", "Appetite Changes", .symptoms, .ios(13, 6)),
    category("BladderIncontinence", "Bladder Incontinence", .symptoms, .ios(14)),
    category("Bloating", "Bloating", .symptoms, .ios(13, 6)),
    category("BreastPain", "Breast Pain", .symptoms, .ios(13, 6)),
    category("ChestTightnessOrPain", "Chest Tightness or Pain", .symptoms, .ios(13, 6)),
    category("Chills", "Chills", .symptoms, .ios(13, 6)),
    category("Constipation", "Constipation", .symptoms, .ios(13, 6)),
    category("Coughing", "Coughing", .symptoms, .ios(13, 6)),
    category("Diarrhea", "Diarrhea", .symptoms, .ios(13, 6)),
    category("Dizziness", "Dizziness", .symptoms, .ios(13, 6)),
    category("DrySkin", "Dry Skin", .symptoms, .ios(14)),
    category("Fainting", "Fainting", .symptoms, .ios(13, 6)),
    category("Fatigue", "Fatigue", .symptoms, .ios(13, 6)),
    category("Fever", "Fever", .symptoms, .ios(13, 6)),
    category("GeneralizedBodyAche", "Body and Muscle Ache", .symptoms, .ios(13, 6)),
    category("HairLoss", "Hair Loss", .symptoms, .ios(14)),
    category("Headache", "Headache", .symptoms, .ios(13, 6)),
    category("Heartburn", "Heartburn", .symptoms, .ios(13, 6)),
    category("HotFlashes", "Hot Flashes", .symptoms, .ios(13, 6)),
    category("LossOfSmell", "Loss of Smell", .symptoms, .ios(13, 6)),
    category("LossOfTaste", "Loss of Taste", .symptoms, .ios(13, 6)),
    category("LowerBackPain", "Lower Back Pain", .symptoms, .ios(13, 6)),
    category("MemoryLapse", "Memory Lapse", .symptoms, .ios(14)),
    category("MoodChanges", "Mood Changes", .symptoms, .ios(13, 6)),
    category("Nausea", "Nausea", .symptoms, .ios(13, 6)),
    category("NightSweats", "Night Sweats", .symptoms, .ios(14)),
    category("PelvicPain", "Pelvic Pain", .symptoms, .ios(13, 6)),
    category(
      "RapidPoundingOrFlutteringHeartbeat", "Rapid, Pounding, or Fluttering Heartbeat", .symptoms,
      .ios(13, 6)
    ),
    category("RunnyNose", "Runny Nose", .symptoms, .ios(13, 6)),
    category("ShortnessOfBreath", "Shortness of Breath", .symptoms, .ios(13, 6)),
    category("SinusCongestion", "Sinus Congestion", .symptoms, .ios(13, 6)),
    category("SkippedHeartbeat", "Skipped Heartbeat", .symptoms, .ios(13, 6)),
    category("SleepChanges", "Sleep Changes", .symptoms, .ios(13, 6)),
    category("SoreThroat", "Sore Throat", .symptoms, .ios(13, 6)),
    category("VaginalDryness", "Vaginal Dryness", .symptoms, .ios(14)),
    category("Vomiting", "Vomiting", .symptoms, .ios(13, 6)),
    category("Wheezing", "Wheezing", .symptoms, .ios(13, 6)),
  ]

  static let vitals: [HealthDataType] = [
    quantity("BodyTemperature", "Body Temperature", .vitals, "degC", .discreteArithmetic, .ios(8)),
    quantity("BloodGlucose", "Blood Glucose", .vitals, "mg/dL", .discreteArithmetic, .ios(8)),
  ]

  static let otherData: [HealthDataType] = [
    quantity(
      "BloodAlcoholContent", "Blood Alcohol Content", .otherData, "%", .discreteArithmetic, .ios(8)
    ),
    quantity(
      "NumberOfAlcoholicBeverages", "Alcoholic Beverages", .otherData, "count", .cumulative,
      .ios(15)
    ),
    quantity("InsulinDelivery", "Insulin Delivery", .otherData, "IU", .cumulative, .ios(11)),
    quantity(
      "NumberOfTimesFallen", "Number of Times Fallen", .otherData, "count", .cumulative, .ios(8)
    ),
    quantity(
      "PeripheralPerfusionIndex", "Peripheral Perfusion Index", .otherData, "%",
      .discreteArithmetic, .ios(8)
    ),
    quantity("UVExposure", "UV Index", .otherData, "count", .discreteArithmetic, .ios(9)),
    quantity("UnderwaterDepth", "Underwater Depth", .otherData, "m", .discreteArithmetic, .ios(16)),
    quantity(
      "WaterTemperature", "Water Temperature", .otherData, "degC", .discreteArithmetic, .ios(16)
    ),
    category("HandwashingEvent", "Handwashing", .otherData, .ios(14)),
    category("ToothbrushingEvent", "Toothbrushing", .otherData, .ios(13)),
    special(
      "HKVisionPrescriptionTypeIdentifier", .visionPrescription, "Vision Prescriptions",
      .otherData, .ios(16), readAuthorization: .perObject
    ),
    special(
      "HKDocumentTypeIdentifierCDA", .document, "Health Documents (CDA)", .otherData, .ios(10)),
  ]

  /// Health Details (profile) values. Health shows them in Health Details, not Browse.
  static let characteristics: [HealthDataType] = [
    characteristic("DateOfBirth", "Date of Birth", .ios(8)),
    characteristic("BiologicalSex", "Sex", .ios(8)),
    characteristic("BloodType", "Blood Type", .ios(8)),
    characteristic("FitzpatrickSkinType", "Fitzpatrick Skin Type", .ios(9)),
    characteristic("WheelchairUse", "Wheelchair", .ios(10)),
    characteristic("ActivityMoveMode", "Activity Move Mode", .ios(14)),
  ]
}

// MARK: - Builders

extension HealthCatalog {
  private static func quantity(
    _ name: String,
    _ displayName: String,
    _ category: HealthCategory,
    _ unit: String,
    _ aggregation: HealthDataType.Aggregation,
    _ introduced: IOSVersion,
    alsoListedIn: Set<HealthCategory> = [],
    readAuthorization: HealthDataType.ReadAuthorization = .standard
  ) -> HealthDataType {
    HealthDataType(
      id: "HKQuantityTypeIdentifier\(name)",
      kind: .quantity,
      name: displayName,
      category: category,
      alsoListedIn: alsoListedIn,
      unit: unit,
      aggregation: aggregation,
      introduced: introduced,
      readAuthorization: readAuthorization
    )
  }

  private static func category(
    _ name: String,
    _ displayName: String,
    _ category: HealthCategory,
    _ introduced: IOSVersion
  ) -> HealthDataType {
    special("HKCategoryTypeIdentifier\(name)", .category, displayName, category, introduced)
  }

  private static func correlation(
    _ name: String,
    _ displayName: String,
    _ category: HealthCategory,
    _ introduced: IOSVersion,
    alsoListedIn: Set<HealthCategory> = []
  ) -> HealthDataType {
    special(
      "HKCorrelationTypeIdentifier\(name)", .correlation, displayName, category, introduced,
      alsoListedIn: alsoListedIn, readAuthorization: .throughComponents
    )
  }

  private static func characteristic(
    _ name: String,
    _ displayName: String,
    _ introduced: IOSVersion
  ) -> HealthDataType {
    special(
      "HKCharacteristicTypeIdentifier\(name)", .characteristic, displayName, nil, introduced
    )
  }

  private static func special(
    _ id: String,
    _ kind: HealthDataType.Kind,
    _ displayName: String,
    _ category: HealthCategory?,
    _ introduced: IOSVersion,
    alsoListedIn: Set<HealthCategory> = [],
    readAuthorization: HealthDataType.ReadAuthorization = .standard
  ) -> HealthDataType {
    HealthDataType(
      id: id,
      kind: kind,
      name: displayName,
      category: category,
      alsoListedIn: alsoListedIn,
      unit: nil,
      aggregation: nil,
      introduced: introduced,
      readAuthorization: readAuthorization
    )
  }
}
