/// How Health names and draws a workout's activity (`HKWorkoutActivityType`'s raw value).
/// Types not listed read "Workout".
enum WorkoutActivity {
  static func name(_ activityType: Int) -> String {
    entries[activityType]?.name ?? "Workout"
  }

  static func symbol(_ activityType: Int) -> String {
    entries[activityType]?.symbol ?? "figure.mixed.cardio"
  }

  /// Whether pace (time per kilometer) means something for it, rather than speed.
  static func hasPace(_ activityType: Int) -> Bool {
    [37, 52, 24, 70, 71].contains(activityType)
  }

  private static let entries: [Int: (name: String, symbol: String)] = [
    13: ("Cycling", "figure.outdoor.cycle"),
    14: ("Dance", "figure.dance"),
    16: ("Elliptical", "figure.elliptical"),
    20: ("Functional Strength Training", "figure.strengthtraining.functional"),
    24: ("Hiking", "figure.hiking"),
    35: ("Rowing", "figure.rower"),
    37: ("Running", "figure.run"),
    44: ("Stair Stepper", "figure.stair.stepper"),
    46: ("Swimming", "figure.pool.swim"),
    50: ("Traditional Strength Training", "figure.strengthtraining.traditional"),
    52: ("Walking", "figure.walk"),
    57: ("Yoga", "figure.yoga"),
    58: ("Barre", "figure.barre"),
    59: ("Core Training", "figure.core.training"),
    62: ("Flexibility", "figure.flexibility"),
    63: ("High Intensity Interval Training", "figure.highintensity.intervaltraining"),
    66: ("Pilates", "figure.pilates"),
    70: ("Wheelchair Walk Pace", "figure.roll"),
    71: ("Wheelchair Run Pace", "figure.roll.runningpace"),
    73: ("Mixed Cardio", "figure.mixed.cardio"),
    77: ("Cardio Dance", "figure.dance"),
    80: ("Cooldown", "figure.cooldown"),
    3000: ("Other", "figure.mixed.cardio"),
  ]
}
