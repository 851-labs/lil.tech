import HealthCatalog

/// How Health names and draws a workout's activity (`HKWorkoutActivityType`'s raw value). Names
/// come from the catalog, which the server shares. Types not listed read "Workout".
enum WorkoutActivity {
  static func name(_ activityType: Int) -> String {
    HealthCatalog.workoutActivityName(activityType)
  }

  static func symbol(_ activityType: Int) -> String {
    symbols[activityType] ?? "figure.mixed.cardio"
  }

  /// Whether pace (time per kilometer) means something for it, rather than speed.
  static func hasPace(_ activityType: Int) -> Bool {
    [37, 52, 24, 70, 71].contains(activityType)
  }

  private static let symbols: [Int: String] = [
    13: "figure.outdoor.cycle",
    14: "figure.dance",
    16: "figure.elliptical",
    20: "figure.strengthtraining.functional",
    24: "figure.hiking",
    35: "figure.rower",
    37: "figure.run",
    44: "figure.stair.stepper",
    46: "figure.pool.swim",
    50: "figure.strengthtraining.traditional",
    52: "figure.walk",
    57: "figure.yoga",
    58: "figure.barre",
    59: "figure.core.training",
    62: "figure.flexibility",
    63: "figure.highintensity.intervaltraining",
    66: "figure.pilates",
    70: "figure.roll",
    71: "figure.roll.runningpace",
    73: "figure.mixed.cardio",
    77: "figure.dance",
    80: "figure.cooldown",
    3000: "figure.mixed.cardio",
  ]
}
