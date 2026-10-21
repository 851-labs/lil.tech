/// How Health names a workout's activity, by `HKWorkoutActivityType`'s raw value. The Mac shows
/// these names, and the server gives them to agents (`Services/api/health-catalog.json`).
extension HealthCatalog {
  /// Names of the activities the Mac knows. Others read `otherWorkoutActivityName`.
  public static let workoutActivityNames: [Int: String] = [
    13: "Cycling",
    14: "Dance",
    16: "Elliptical",
    20: "Functional Strength Training",
    24: "Hiking",
    35: "Rowing",
    37: "Running",
    44: "Stair Stepper",
    46: "Swimming",
    50: "Traditional Strength Training",
    52: "Walking",
    57: "Yoga",
    58: "Barre",
    59: "Core Training",
    62: "Flexibility",
    63: "High Intensity Interval Training",
    66: "Pilates",
    70: "Wheelchair Walk Pace",
    71: "Wheelchair Run Pace",
    73: "Mixed Cardio",
    77: "Cardio Dance",
    80: "Cooldown",
    3000: "Other",
  ]

  /// The name of an activity the catalog doesn't know.
  public static let otherWorkoutActivityName = "Workout"

  public static func workoutActivityName(_ activityType: Int) -> String {
    workoutActivityNames[activityType] ?? otherWorkoutActivityName
  }
}
