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

  public static func type(id: String) -> HealthDataType? {
    byID[id]
  }

  public static func types(in category: HealthCategory) -> [HealthDataType] {
    all.filter { $0.category == category }
  }

  /// Types available on a given iOS version, e.g. to request authorization.
  public static func types(availableOn version: IOSVersion) -> [HealthDataType] {
    all.filter { $0.introduced <= version }
  }
}

// MARK: - Categories

extension HealthCatalog {
  static let activity: [HealthDataType] = [
    quantity("StepCount", "Steps", .activity, "count", .cumulative, (8, 0)),
    quantity(
      "DistanceWalkingRunning", "Walking + Running Distance", .activity, "m", .cumulative, (8, 0)
    ),
    quantity("ActiveEnergyBurned", "Active Energy", .activity, "kcal", .cumulative, (8, 0)),
    quantity("BasalEnergyBurned", "Resting Energy", .activity, "kcal", .cumulative, (8, 0)),
    quantity("AppleExerciseTime", "Exercise Minutes", .activity, "min", .cumulative, (9, 3)),
    quantity("AppleMoveTime", "Move Minutes", .activity, "min", .cumulative, (14, 5)),
    quantity("AppleStandTime", "Stand Minutes", .activity, "min", .cumulative, (13, 0)),
    category("AppleStandHour", "Stand Hours", .activity, (9, 0)),
    quantity("FlightsClimbed", "Flights Climbed", .activity, "count", .cumulative, (8, 0)),
    quantity("PushCount", "Pushes", .activity, "count", .cumulative, (10, 0)),
    quantity("DistanceWheelchair", "Wheelchair Distance", .activity, "m", .cumulative, (10, 0)),
    quantity("DistanceCycling", "Cycling Distance", .activity, "m", .cumulative, (8, 0)),
    quantity(
      "CyclingCadence", "Cycling Cadence", .activity, "count/min", .discreteTemporallyWeighted,
      (17, 0)
    ),
    quantity(
      "CyclingFunctionalThresholdPower", "Cycling Functional Threshold Power", .activity, "W",
      .discreteArithmetic, (17, 0)
    ),
    quantity(
      "CyclingPower", "Cycling Power", .activity, "W", .discreteTemporallyWeighted, (17, 0)
    ),
    quantity(
      "CyclingSpeed", "Cycling Speed", .activity, "m/s", .discreteTemporallyWeighted, (17, 0)
    ),
    quantity("DistanceSwimming", "Swimming Distance", .activity, "m", .cumulative, (10, 0)),
    quantity("SwimmingStrokeCount", "Swimming Strokes", .activity, "count", .cumulative, (10, 0)),
    quantity(
      "DistanceDownhillSnowSports", "Downhill Snow Sports Distance", .activity, "m", .cumulative,
      (11, 2)
    ),
    quantity(
      "DistanceCrossCountrySkiing", "Cross-Country Skiing Distance", .activity, "m", .cumulative,
      (18, 0)
    ),
    quantity(
      "CrossCountrySkiingSpeed", "Cross-Country Skiing Speed", .activity, "m/s",
      .discreteArithmetic, (18, 0)
    ),
    quantity(
      "DistancePaddleSports", "Paddle Sports Distance", .activity, "m", .cumulative, (18, 0)
    ),
    quantity(
      "PaddleSportsSpeed", "Paddle Sports Speed", .activity, "m/s", .discreteArithmetic, (18, 0)
    ),
    quantity("DistanceRowing", "Rowing Distance", .activity, "m", .cumulative, (18, 0)),
    quantity("RowingSpeed", "Rowing Speed", .activity, "m/s", .discreteArithmetic, (18, 0)),
    quantity(
      "DistanceSkatingSports", "Skating Sports Distance", .activity, "m", .cumulative, (18, 0)
    ),
    quantity("RunningPower", "Running Power", .activity, "W", .discreteArithmetic, (16, 0)),
    quantity("RunningSpeed", "Running Speed", .activity, "m/s", .discreteArithmetic, (16, 0)),
    quantity(
      "PhysicalEffort", "Physical Effort", .activity, "kcal/(kg*hr)", .discreteArithmetic, (17, 0)
    ),
    quantity(
      "WorkoutEffortScore", "Workout Effort", .activity, "appleEffortScore", .discreteArithmetic,
      (18, 0)
    ),
    quantity(
      "EstimatedWorkoutEffortScore", "Estimated Workout Effort", .activity, "appleEffortScore",
      .discreteArithmetic, (18, 0)
    ),
    quantity("NikeFuel", "NikeFuel", .activity, "count", .cumulative, (8, 0)),
    special("HKWorkoutTypeIdentifier", .workout, "Workouts", .activity, (8, 0)),
    special("HKWorkoutRouteTypeIdentifier", .workoutRoute, "Workout Routes", .activity, (11, 0)),
    special(
      "HKActivitySummaryTypeIdentifier", .activitySummary, "Activity Rings", .activity, (9, 3)
    ),
  ]

  static let bodyMeasurements: [HealthDataType] = [
    quantity("BodyMass", "Weight", .bodyMeasurements, "kg", .discreteArithmetic, (8, 0)),
    quantity("Height", "Height", .bodyMeasurements, "m", .discreteArithmetic, (8, 0)),
    quantity(
      "BodyMassIndex", "Body Mass Index", .bodyMeasurements, "count", .discreteArithmetic, (8, 0)
    ),
    quantity(
      "BodyFatPercentage", "Body Fat Percentage", .bodyMeasurements, "%", .discreteArithmetic,
      (8, 0)
    ),
    quantity(
      "LeanBodyMass", "Lean Body Mass", .bodyMeasurements, "kg", .discreteArithmetic, (8, 0)),
    quantity(
      "WaistCircumference", "Waist Circumference", .bodyMeasurements, "m", .discreteArithmetic,
      (11, 0)
    ),
    quantity(
      "AppleSleepingWristTemperature", "Wrist Temperature", .bodyMeasurements, "degC",
      .discreteArithmetic, (16, 0)
    ),
    quantity(
      "ElectrodermalActivity", "Electrodermal Activity", .bodyMeasurements, "mcS",
      .discreteArithmetic, (8, 0)
    ),
  ]

  static let cycleTracking: [HealthDataType] = [
    category("MenstrualFlow", "Period", .cycleTracking, (9, 0)),
    quantity(
      "BasalBodyTemperature", "Basal Body Temperature", .cycleTracking, "degC",
      .discreteArithmetic, (9, 0)
    ),
    category("CervicalMucusQuality", "Cervical Mucus Quality", .cycleTracking, (9, 0)),
    category("OvulationTestResult", "Ovulation Test Result", .cycleTracking, (9, 0)),
    category("PregnancyTestResult", "Pregnancy Test Result", .cycleTracking, (15, 0)),
    category("ProgesteroneTestResult", "Progesterone Test Result", .cycleTracking, (15, 0)),
    category("IntermenstrualBleeding", "Spotting", .cycleTracking, (9, 0)),
    category("SexualActivity", "Sexual Activity", .cycleTracking, (9, 0)),
    category("Contraceptive", "Contraceptives", .cycleTracking, (14, 3)),
    category("Lactation", "Lactation", .cycleTracking, (14, 3)),
    category("Pregnancy", "Pregnancy", .cycleTracking, (14, 3)),
    category("BleedingDuringPregnancy", "Bleeding During Pregnancy", .cycleTracking, (18, 0)),
    category("BleedingAfterPregnancy", "Bleeding After Pregnancy", .cycleTracking, (18, 0)),
    category("BleedingAfterMenopause", "Bleeding After Menopause", .cycleTracking, (27, 0)),
    category("MenopausalState", "Menopause", .cycleTracking, (27, 0)),
    category("InfrequentMenstrualCycles", "Infrequent Periods", .cycleTracking, (16, 0)),
    category("IrregularMenstrualCycles", "Irregular Cycles", .cycleTracking, (16, 0)),
    category(
      "PersistentIntermenstrualBleeding", "Persistent Spotting", .cycleTracking, (16, 0)
    ),
    category("ProlongedMenstrualPeriods", "Prolonged Periods", .cycleTracking, (16, 0)),
  ]

  static let hearing: [HealthDataType] = [
    quantity(
      "EnvironmentalAudioExposure", "Environmental Sound Levels", .hearing, "dBASPL",
      .discreteEquivalentContinuousLevel, (13, 0)
    ),
    quantity(
      "HeadphoneAudioExposure", "Headphone Audio Levels", .hearing, "dBASPL",
      .discreteEquivalentContinuousLevel, (13, 0)
    ),
    quantity(
      "EnvironmentalSoundReduction", "Environmental Sound Reduction", .hearing, "dBASPL",
      .discreteEquivalentContinuousLevel, (16, 0)
    ),
    category(
      "EnvironmentalAudioExposureEvent", "Noise Notifications", .hearing, (14, 0)
    ),
    category(
      "HeadphoneAudioExposureEvent", "Headphone Notifications", .hearing, (14, 2)
    ),
    special("HKDataTypeIdentifierAudiogram", .audiogram, "Audiograms", .hearing, (13, 0)),
  ]

  static let heart: [HealthDataType] = [
    quantity("HeartRate", "Heart Rate", .heart, "count/min", .discreteTemporallyWeighted, (8, 0)),
    quantity(
      "RestingHeartRate", "Resting Heart Rate", .heart, "count/min", .discreteTemporallyWeighted,
      (11, 0)
    ),
    quantity(
      "WalkingHeartRateAverage", "Walking Heart Rate Average", .heart, "count/min",
      .discreteTemporallyWeighted, (11, 0)
    ),
    quantity(
      "HeartRateVariabilitySDNN", "Heart Rate Variability", .heart, "ms", .discreteArithmetic,
      (11, 0)
    ),
    quantity(
      "HeartRateVariabilityRMSSD", "Heart Rate Variability (RMSSD)", .heart, "ms",
      .discreteArithmetic, (27, 0)
    ),
    quantity(
      "HeartRateRecoveryOneMinute", "Cardio Recovery", .heart, "count/min", .discreteArithmetic,
      (16, 0)
    ),
    quantity("VO2Max", "Cardio Fitness", .heart, "ml/(kg*min)", .discreteArithmetic, (11, 0)),
    quantity(
      "AtrialFibrillationBurden", "AFib History", .heart, "%", .discreteTemporallyWeighted, (16, 0)
    ),
    correlation("BloodPressure", "Blood Pressure", .heart, (8, 0)),
    quantity(
      "BloodPressureSystolic", "Systolic Blood Pressure", .heart, "mmHg", .discreteArithmetic,
      (8, 0)
    ),
    quantity(
      "BloodPressureDiastolic", "Diastolic Blood Pressure", .heart, "mmHg", .discreteArithmetic,
      (8, 0)
    ),
    category("HighHeartRateEvent", "High Heart Rate Notifications", .heart, (12, 2)),
    category("LowHeartRateEvent", "Low Heart Rate Notifications", .heart, (12, 2)),
    category(
      "IrregularHeartRhythmEvent", "Irregular Rhythm Notifications", .heart, (12, 2)
    ),
    category("LowCardioFitnessEvent", "Low Cardio Fitness Notifications", .heart, (14, 3)),
    category("HypertensionEvent", "Hypertension Notifications", .heart, (26, 2)),
    special("HKDataTypeIdentifierElectrocardiogram", .electrocardiogram, "ECG", .heart, (14, 0)),
    special(
      "HKDataTypeIdentifierHeartbeatSeries", .heartbeatSeries, "Heartbeat Series", .heart, (13, 0)
    ),
  ]

  static let medications: [HealthDataType] = [
    special(
      "HKDataTypeUserAnnotatedMedicationConcept", .medication, "Medications", .medications,
      (26, 0)
    ),
    special(
      "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent", .medicationDoseEvent,
      "Medication Doses", .medications, (26, 0)
    ),
  ]

  static let mentalWellbeing: [HealthDataType] = [
    special("HKDataTypeStateOfMind", .stateOfMind, "State of Mind", .mentalWellbeing, (18, 0)),
    category("MindfulSession", "Mindful Minutes", .mentalWellbeing, (10, 0)),
    quantity(
      "TimeInDaylight", "Time in Daylight", .mentalWellbeing, "min", .cumulative, (17, 0)
    ),
    special(
      "HKScoredAssessmentTypeIdentifierGAD7", .scoredAssessment, "Anxiety Risk (GAD-7)",
      .mentalWellbeing, (18, 0)
    ),
    special(
      "HKScoredAssessmentTypeIdentifierPHQ9", .scoredAssessment, "Depression Risk (PHQ-9)",
      .mentalWellbeing, (18, 0)
    ),
  ]

  static let mobility: [HealthDataType] = [
    quantity("WalkingSpeed", "Walking Speed", .mobility, "m/s", .discreteArithmetic, (14, 0)),
    quantity(
      "WalkingStepLength", "Walking Step Length", .mobility, "m", .discreteArithmetic, (14, 0)),
    quantity(
      "WalkingAsymmetryPercentage", "Walking Asymmetry", .mobility, "%", .discreteArithmetic,
      (14, 0)
    ),
    quantity(
      "WalkingDoubleSupportPercentage", "Double Support Time", .mobility, "%", .discreteArithmetic,
      (14, 0)
    ),
    quantity(
      "AppleWalkingSteadiness", "Walking Steadiness", .mobility, "%", .discreteArithmetic, (15, 0)
    ),
    category(
      "AppleWalkingSteadinessEvent", "Walking Steadiness Notifications", .mobility, (15, 0)
    ),
    quantity(
      "SixMinuteWalkTestDistance", "Six-Minute Walk", .mobility, "m", .discreteArithmetic, (14, 0)
    ),
    quantity("StairAscentSpeed", "Stair Speed: Up", .mobility, "m/s", .discreteArithmetic, (14, 0)),
    quantity(
      "StairDescentSpeed", "Stair Speed: Down", .mobility, "m/s", .discreteArithmetic, (14, 0)
    ),
    quantity(
      "RunningStrideLength", "Running Stride Length", .mobility, "m", .discreteArithmetic, (16, 0)
    ),
    quantity(
      "RunningGroundContactTime", "Ground Contact Time", .mobility, "ms", .discreteArithmetic,
      (16, 0)
    ),
    quantity(
      "RunningVerticalOscillation", "Vertical Oscillation", .mobility, "cm", .discreteArithmetic,
      (16, 0)
    ),
  ]

  static let nutrition: [HealthDataType] = [
    correlation("Food", "Food", .nutrition, (8, 0)),
    quantity("DietaryEnergyConsumed", "Dietary Energy", .nutrition, "kcal", .cumulative, (8, 0)),
    quantity("DietaryWater", "Water", .nutrition, "mL", .cumulative, (9, 0)),
    quantity("DietaryCaffeine", "Caffeine", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryCarbohydrates", "Carbohydrates", .nutrition, "g", .cumulative, (8, 0)),
    quantity("DietaryFiber", "Fiber", .nutrition, "g", .cumulative, (8, 0)),
    quantity("DietarySugar", "Dietary Sugar", .nutrition, "g", .cumulative, (8, 0)),
    quantity("DietaryProtein", "Protein", .nutrition, "g", .cumulative, (8, 0)),
    quantity("DietaryFatTotal", "Total Fat", .nutrition, "g", .cumulative, (8, 0)),
    quantity("DietaryFatSaturated", "Saturated Fat", .nutrition, "g", .cumulative, (8, 0)),
    quantity(
      "DietaryFatMonounsaturated", "Monounsaturated Fat", .nutrition, "g", .cumulative, (8, 0)
    ),
    quantity(
      "DietaryFatPolyunsaturated", "Polyunsaturated Fat", .nutrition, "g", .cumulative, (8, 0)
    ),
    quantity("DietaryCholesterol", "Dietary Cholesterol", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietarySodium", "Sodium", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryPotassium", "Potassium", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryCalcium", "Calcium", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryChloride", "Chloride", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryIron", "Iron", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryMagnesium", "Magnesium", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryManganese", "Manganese", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryPhosphorus", "Phosphorus", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryZinc", "Zinc", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryCopper", "Copper", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryChromium", "Chromium", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryIodine", "Iodine", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryMolybdenum", "Molybdenum", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietarySelenium", "Selenium", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryVitaminA", "Vitamin A", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryThiamin", "Thiamin", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryRiboflavin", "Riboflavin", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryNiacin", "Niacin", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryPantothenicAcid", "Pantothenic Acid", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryVitaminB6", "Vitamin B6", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryBiotin", "Biotin", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryFolate", "Folate", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryVitaminB12", "Vitamin B12", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryVitaminC", "Vitamin C", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryVitaminD", "Vitamin D", .nutrition, "mcg", .cumulative, (8, 0)),
    quantity("DietaryVitaminE", "Vitamin E", .nutrition, "mg", .cumulative, (8, 0)),
    quantity("DietaryVitaminK", "Vitamin K", .nutrition, "mcg", .cumulative, (8, 0)),
  ]

  static let respiratory: [HealthDataType] = [
    quantity(
      "RespiratoryRate", "Respiratory Rate", .respiratory, "count/min", .discreteArithmetic,
      (8, 0)
    ),
    quantity("OxygenSaturation", "Blood Oxygen", .respiratory, "%", .discreteArithmetic, (8, 0)),
    quantity(
      "AppleSleepingBreathingDisturbances", "Breathing Disturbances", .respiratory, "count",
      .discreteArithmetic, (18, 0)
    ),
    category("SleepApneaEvent", "Sleep Apnea Notifications", .respiratory, (18, 0)),
    quantity(
      "ForcedVitalCapacity", "Forced Vital Capacity", .respiratory, "L", .discreteArithmetic, (8, 0)
    ),
    quantity(
      "ForcedExpiratoryVolume1", "Forced Expiratory Volume, 1 sec", .respiratory, "L",
      .discreteArithmetic, (8, 0)
    ),
    quantity(
      "PeakExpiratoryFlowRate", "Peak Expiratory Flow Rate", .respiratory, "L/min",
      .discreteArithmetic, (8, 0)
    ),
    quantity("InhalerUsage", "Inhaler Usage", .respiratory, "count", .cumulative, (8, 0)),
  ]

  static let sleep: [HealthDataType] = [
    category("SleepAnalysis", "Sleep", .sleep, (8, 0))
  ]

  static let symptoms: [HealthDataType] = [
    category("AbdominalCramps", "Abdominal Cramps", .symptoms, (13, 6)),
    category("Acne", "Acne", .symptoms, (13, 6)),
    category("AppetiteChanges", "Appetite Changes", .symptoms, (13, 6)),
    category("BladderIncontinence", "Bladder Incontinence", .symptoms, (14, 0)),
    category("Bloating", "Bloating", .symptoms, (13, 6)),
    category("BreastPain", "Breast Pain", .symptoms, (13, 6)),
    category("ChestTightnessOrPain", "Chest Tightness or Pain", .symptoms, (13, 6)),
    category("Chills", "Chills", .symptoms, (13, 6)),
    category("Constipation", "Constipation", .symptoms, (13, 6)),
    category("Coughing", "Coughing", .symptoms, (13, 6)),
    category("Diarrhea", "Diarrhea", .symptoms, (13, 6)),
    category("Dizziness", "Dizziness", .symptoms, (13, 6)),
    category("DrySkin", "Dry Skin", .symptoms, (14, 0)),
    category("Fainting", "Fainting", .symptoms, (13, 6)),
    category("Fatigue", "Fatigue", .symptoms, (13, 6)),
    category("Fever", "Fever", .symptoms, (13, 6)),
    category("GeneralizedBodyAche", "Body and Muscle Ache", .symptoms, (13, 6)),
    category("HairLoss", "Hair Loss", .symptoms, (14, 0)),
    category("Headache", "Headache", .symptoms, (13, 6)),
    category("Heartburn", "Heartburn", .symptoms, (13, 6)),
    category("HotFlashes", "Hot Flashes", .symptoms, (13, 6)),
    category("LossOfSmell", "Loss of Smell", .symptoms, (13, 6)),
    category("LossOfTaste", "Loss of Taste", .symptoms, (13, 6)),
    category("LowerBackPain", "Lower Back Pain", .symptoms, (13, 6)),
    category("MemoryLapse", "Memory Lapse", .symptoms, (14, 0)),
    category("MoodChanges", "Mood Changes", .symptoms, (13, 6)),
    category("Nausea", "Nausea", .symptoms, (13, 6)),
    category("NightSweats", "Night Sweats", .symptoms, (14, 0)),
    category("PelvicPain", "Pelvic Pain", .symptoms, (13, 6)),
    category(
      "RapidPoundingOrFlutteringHeartbeat", "Rapid, Pounding, or Fluttering Heartbeat", .symptoms,
      (13, 6)
    ),
    category("RunnyNose", "Runny Nose", .symptoms, (13, 6)),
    category("ShortnessOfBreath", "Shortness of Breath", .symptoms, (13, 6)),
    category("SinusCongestion", "Sinus Congestion", .symptoms, (13, 6)),
    category("SkippedHeartbeat", "Skipped Heartbeat", .symptoms, (13, 6)),
    category("SleepChanges", "Sleep Changes", .symptoms, (13, 6)),
    category("SoreThroat", "Sore Throat", .symptoms, (13, 6)),
    category("VaginalDryness", "Vaginal Dryness", .symptoms, (14, 0)),
    category("Vomiting", "Vomiting", .symptoms, (13, 6)),
    category("Wheezing", "Wheezing", .symptoms, (13, 6)),
  ]

  static let vitals: [HealthDataType] = [
    quantity("BodyTemperature", "Body Temperature", .vitals, "degC", .discreteArithmetic, (8, 0)),
    quantity("BloodGlucose", "Blood Glucose", .vitals, "mg/dL", .discreteArithmetic, (8, 0)),
  ]

  static let otherData: [HealthDataType] = [
    quantity(
      "BloodAlcoholContent", "Blood Alcohol Content", .otherData, "%", .discreteArithmetic, (8, 0)
    ),
    quantity(
      "NumberOfAlcoholicBeverages", "Alcoholic Beverages", .otherData, "count", .cumulative,
      (15, 0)
    ),
    quantity("InsulinDelivery", "Insulin Delivery", .otherData, "IU", .cumulative, (11, 0)),
    quantity(
      "NumberOfTimesFallen", "Number of Times Fallen", .otherData, "count", .cumulative, (8, 0)
    ),
    quantity(
      "PeripheralPerfusionIndex", "Peripheral Perfusion Index", .otherData, "%",
      .discreteArithmetic, (8, 0)
    ),
    quantity("UVExposure", "UV Index", .otherData, "count", .discreteArithmetic, (9, 0)),
    quantity("UnderwaterDepth", "Underwater Depth", .otherData, "m", .discreteArithmetic, (16, 0)),
    quantity(
      "WaterTemperature", "Water Temperature", .otherData, "degC", .discreteArithmetic, (16, 0)
    ),
    category("HandwashingEvent", "Handwashing", .otherData, (14, 0)),
    category("ToothbrushingEvent", "Toothbrushing", .otherData, (13, 0)),
    special(
      "HKVisionPrescriptionTypeIdentifier", .visionPrescription, "Vision Prescriptions",
      .otherData, (16, 0)
    ),
    special(
      "HKDocumentTypeIdentifierCDA", .document, "Health Documents (CDA)", .otherData, (10, 0)),
  ]

  /// Health Details (profile) values. They have no Browse category; Health shows them in the
  /// profile, so they sit under Other Data.
  static let characteristics: [HealthDataType] = [
    characteristic("DateOfBirth", "Date of Birth", (8, 0)),
    characteristic("BiologicalSex", "Sex", (8, 0)),
    characteristic("BloodType", "Blood Type", (8, 0)),
    characteristic("FitzpatrickSkinType", "Fitzpatrick Skin Type", (9, 0)),
    characteristic("WheelchairUse", "Wheelchair", (10, 0)),
    characteristic("ActivityMoveMode", "Activity Move Mode", (14, 0)),
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
    _ introduced: (Int, Int)
  ) -> HealthDataType {
    HealthDataType(
      id: "HKQuantityTypeIdentifier\(name)",
      kind: .quantity,
      name: displayName,
      category: category,
      unit: unit,
      aggregation: aggregation,
      introduced: IOSVersion(introduced.0, introduced.1)
    )
  }

  private static func category(
    _ name: String,
    _ displayName: String,
    _ category: HealthCategory,
    _ introduced: (Int, Int)
  ) -> HealthDataType {
    special("HKCategoryTypeIdentifier\(name)", .category, displayName, category, introduced)
  }

  private static func correlation(
    _ name: String,
    _ displayName: String,
    _ category: HealthCategory,
    _ introduced: (Int, Int)
  ) -> HealthDataType {
    special("HKCorrelationTypeIdentifier\(name)", .correlation, displayName, category, introduced)
  }

  private static func characteristic(
    _ name: String,
    _ displayName: String,
    _ introduced: (Int, Int)
  ) -> HealthDataType {
    special(
      "HKCharacteristicTypeIdentifier\(name)", .characteristic, displayName, .otherData, introduced
    )
  }

  private static func special(
    _ id: String,
    _ kind: HealthDataType.Kind,
    _ displayName: String,
    _ category: HealthCategory,
    _ introduced: (Int, Int)
  ) -> HealthDataType {
    HealthDataType(
      id: id,
      kind: kind,
      name: displayName,
      category: category,
      unit: nil,
      aggregation: nil,
      introduced: IOSVersion(introduced.0, introduced.1)
    )
  }
}
