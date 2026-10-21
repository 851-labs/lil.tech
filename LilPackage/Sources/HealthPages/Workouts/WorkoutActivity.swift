import HealthCatalog

/// How Health names and draws a workout's activity (`HKWorkoutActivityType`'s raw value). Names
/// come from the catalog, which the server shares. Values a later iOS adds read "Workout".
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

  /// Every activity the catalog names, and only those (`WorkoutFormatTests`, which also checks
  /// that each symbol exists).
  static let symbols: [Int: String] = [
    1: "figure.american.football",
    2: "figure.archery",
    3: "figure.australian.football",
    4: "figure.badminton",
    5: "figure.baseball",
    6: "figure.basketball",
    7: "figure.bowling",
    8: "figure.boxing",
    9: "figure.climbing",
    10: "figure.cricket",
    11: "figure.cross.training",
    12: "figure.curling",
    13: "figure.outdoor.cycle",
    14: "figure.dance",
    15: "figure.dance",
    16: "figure.elliptical",
    17: "figure.equestrian.sports",
    18: "figure.fencing",
    19: "figure.fishing",
    20: "figure.strengthtraining.functional",
    21: "figure.golf",
    22: "figure.gymnastics",
    23: "figure.handball",
    24: "figure.hiking",
    25: "figure.hockey",
    26: "figure.hunting",
    27: "figure.lacrosse",
    28: "figure.martial.arts",
    29: "figure.mind.and.body",
    30: "figure.mixed.cardio",
    31: "figure.outdoor.rowing",
    32: "figure.play",
    33: "figure.rolling",
    34: "figure.racquetball",
    35: "figure.rower",
    36: "figure.rugby",
    37: "figure.run",
    38: "figure.sailing",
    39: "figure.skating",
    40: "snowflake",
    41: "figure.soccer",
    42: "figure.softball",
    43: "figure.squash",
    44: "figure.stair.stepper",
    45: "figure.surfing",
    46: "figure.pool.swim",
    47: "figure.table.tennis",
    48: "figure.tennis",
    49: "figure.track.and.field",
    50: "figure.strengthtraining.traditional",
    51: "figure.volleyball",
    52: "figure.walk",
    53: "figure.water.fitness",
    54: "figure.waterpolo",
    55: "water.waves",
    56: "figure.wrestling",
    57: "figure.yoga",
    58: "figure.barre",
    59: "figure.core.training",
    60: "figure.skiing.crosscountry",
    61: "figure.skiing.downhill",
    62: "figure.flexibility",
    63: "figure.highintensity.intervaltraining",
    64: "figure.jumprope",
    65: "figure.kickboxing",
    66: "figure.pilates",
    67: "figure.snowboarding",
    68: "figure.stairs",
    69: "figure.step.training",
    70: "figure.roll",
    71: "figure.roll.runningpace",
    72: "figure.taichi",
    73: "figure.mixed.cardio",
    74: "figure.hand.cycling",
    75: "figure.disc.sports",
    76: "gamecontroller",
    77: "figure.dance",
    78: "figure.socialdance",
    79: "figure.pickleball",
    80: "figure.cooldown",
    82: "figure.run.square.stack",
    83: "figure.walk.motion",
    84: "water.waves.and.arrow.trianglehead.down",
    3000: "figure.mixed.cardio",
  ]
}
