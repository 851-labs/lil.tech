import { Effect, Schema } from "effect";
import { Tool, Toolkit } from "effect/ai";

// The Health toolkit: the tools agents use to read a person's lil health data (851-2841). It's
// defined once, here, and implemented twice: by the API's MCP server from the user's store, and
// by `lil-health mcp` on the Mac from its synced database, which registers its tools from
// `mcp-tools.json` (generated from this file). The conformance cases in
// `test/health/tools/conformance` keep the two giving the same answers.
//
// Every tool is read-only and aggregate-first: outputs are totals, buckets and short lists, with
// caps, never every sample. The definition holds no server code, like `Api.ts`.
//
// Outputs are part of the API's contract: their schemas are in `openapi.json` (so the Swift client
// has their types) and `mcp-tools.json`. Like responses, they can gain fields, but no field can be
// removed or renamed, and enum-like fields are plain strings so that new values don't break
// clients.

// -------------------------------------------------------------------------------------------------
// Shared pieces
// -------------------------------------------------------------------------------------------------

export const timeZone = Schema.optionalKey(
  Schema.String.annotate({
    description:
      "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on " +
      "the remote server and to the Mac's time zone locally. Every output says which it used.",
  }),
);

const range = Schema.Literals(["D", "W", "M", "6M", "Y"]).annotate({
  description:
    "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in " +
    "days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day " +
    "weeks; Y the 12 calendar months ending with that day's month, in months (the last one " +
    "ends with `date`).",
});

/**
 * Any string, as the Mac's `lil-health mcp` takes it: the tool checks it's a day the tools take
 * (`toolDate`), so both servers refuse one that isn't with the same message, `Invalid date: …`
 * (851-4034), and its description and type list in `mcp-tools.json`, which a checked string's
 * don't.
 */
const date = Schema.optionalKey(
  Schema.String.annotate({
    description:
      "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to " +
      "today.",
  }),
);

const healthType = Schema.String.annotate({
  description:
    "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or " +
    "HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them.",
});

export const LocalTime = Schema.String.annotate({
  description:
    "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. " +
    "2026-10-20T08:15:00+01:00.",
});

export const LocalDate = Schema.String.annotate({
  description: "A day in the output's `timeZone`, as YYYY-MM-DD.",
});

export const usedTimeZone = Schema.String.annotate({
  description: "The IANA time zone of the output's days and local times.",
});

const periodFields = {
  timeZone: usedTimeZone,
  range: Schema.String.annotate({ description: "The range asked for: D, W, M, 6M or Y." }),
  start: LocalTime.annotate({ description: "When the period starts." }),
  end: LocalTime.annotate({ description: "When the period ends (exclusive)." }),
};

/** A tool's failure: its message is what the agent sees, e.g. an unknown time zone. */
export class HealthToolError extends Schema.TaggedError<HealthToolError>()("HealthToolError", {
  message: Schema.String,
}) {}

/** Marks a tool read-only, and safe to call again. */
const readOnly = <T extends Tool.Any>(tool: T, title: string): T =>
  tool
    .annotate(Tool.Title, title)
    .annotate(Tool.Readonly, true)
    .annotate(Tool.Destructive, false)
    .annotate(Tool.Idempotent, true)
    .annotate(Tool.OpenWorld, false) as T;

// -------------------------------------------------------------------------------------------------
// summary
// -------------------------------------------------------------------------------------------------

/**
 * What `summary` shows: the everyday metrics most iPhones record, as the Mac's Summary does
 * (`HealthDatabase.summaryTypes`). Pins chose them until they were retired (851-2990).
 */
export const summaryTypes = [
  "HKQuantityTypeIdentifierStepCount",
  "HKQuantityTypeIdentifierHeartRate",
  "HKQuantityTypeIdentifierActiveEnergyBurned",
  "HKQuantityTypeIdentifierDistanceWalkingRunning",
  "HKQuantityTypeIdentifierRestingHeartRate",
  "HKQuantityTypeIdentifierBodyMass",
] as const;

export const HealthSummaryMetric = Schema.Struct({
  type: healthType,
  unit: Schema.NullOr(Schema.String).annotate({
    description:
      "The HealthKit unit of the values, e.g. count, kcal or count/min. Null for category types.",
  }),
  latest: Schema.NullOr(
    Schema.Struct({
      start: LocalTime,
      end: LocalTime,
      value: Schema.NullOr(Schema.Finite).annotate({
        description: "A quantity's value, in `unit`. Null for category types.",
      }),
      categoryValue: Schema.NullOr(Schema.Int).annotate({
        description: "A category sample's HealthKit value (HKCategoryValue…). Null for quantities.",
      }),
    }),
  ).annotate({
    description: "The most recent sample that has started, or null if there's none.",
  }),
  today: Schema.NullOr(Schema.Finite).annotate({
    description:
      "For types that add up (steps, energy, distance): today's total, as Health counts it. " +
      "Null for other types, or with nothing recorded today.",
  }),
  last7Days: Schema.NullOr(Schema.Finite).annotate({
    description:
      "For types that add up: the total over today and the 6 days before. Null for other " +
      "types, or with nothing recorded in those days.",
  }),
}).annotate({ identifier: "HealthSummaryMetric" });

export const HealthSummaryResult = Schema.Struct({
  timeZone: usedTimeZone,
  date: LocalDate.annotate({ description: "Today." }),
  pinned: Schema.Boolean.annotate({
    description:
      "Deprecated: always false. lil health no longer has pinned metrics, so `metrics` are " +
      "always the everyday ones.",
  }),
  metrics: Schema.Array(HealthSummaryMetric).annotate({
    description: "The metrics, in the order Summary shows them.",
  }),
  workouts: Schema.Struct({
    count: Schema.Int,
    duration: Schema.Finite.annotate({ description: "Seconds of activity, excluding pauses." }),
  }).annotate({
    description: "Workouts that started today (by now) or in the 6 days before.",
  }),
});

export const Summary = readOnly(
  Tool.make("summary", {
    description:
      "Start here. An overview of the person's Apple Health data, as lil health's Summary " +
      "shows it: for each everyday metric (steps, heart rate, active energy, walking + running " +
      "distance, resting heart rate, weight), the latest sample and, for types that add up, " +
      "today's and the last 7 days' totals; plus the workouts of the last 7 days (today and " +
      "the 6 days before).",
    parameters: Schema.Struct({ timeZone }),
    success: HealthSummaryResult,
    failure: HealthToolError,
  }),
  "Health Summary",
);

// -------------------------------------------------------------------------------------------------
// list_types
// -------------------------------------------------------------------------------------------------

export const HealthTypeInfo = Schema.Struct({
  type: healthType,
  name: Schema.String.annotate({ description: "The name Health shows, e.g. Steps." }),
  category: Schema.NullOr(Schema.String).annotate({
    description: "The Browse category, e.g. Activity or Heart. Null for characteristics.",
  }),
  kind: Schema.String.annotate({
    description:
      "What kind of data it is: quantity, category, workout, medication, electrocardiogram…",
  }),
  unit: Schema.NullOr(Schema.String).annotate({
    description: "A quantity type's HealthKit unit, e.g. count/min. Null for other kinds.",
  }),
  cumulative: Schema.Boolean.annotate({
    description:
      "Whether values add up (steps, energy), so metric's default statistic is a sum rather " +
      "than an average.",
  }),
  first: LocalTime.annotate({ description: "When the earliest record starts." }),
  last: LocalTime.annotate({ description: "When the latest record starts." }),
}).annotate({ identifier: "HealthTypeInfo" });

export const HealthTypesResult = Schema.Struct({
  timeZone: usedTimeZone,
  types: Schema.Array(HealthTypeInfo).annotate({
    description: "Every type with data, by category, then name.",
  }),
});

export const ListTypes = readOnly(
  Tool.make("list_types", {
    description:
      "Lists the kinds of Health data the person has (only types with data), with each type's " +
      "identifier, name, category, unit and date range. Use the identifiers with metric and " +
      "samples.",
    parameters: Schema.Struct({ timeZone }),
    success: HealthTypesResult,
    failure: HealthToolError,
  }),
  "List Health Data Types",
);

// -------------------------------------------------------------------------------------------------
// metric
// -------------------------------------------------------------------------------------------------

export const HealthMetricBucket = Schema.Struct({
  start: LocalTime,
  value: Schema.NullOr(Schema.Finite).annotate({
    description: "The statistic over the bucket, in `unit`, or null without data.",
  }),
}).annotate({ identifier: "HealthMetricBucket" });

export const HealthMetricResult = Schema.Struct({
  ...periodFields,
  type: healthType,
  unit: Schema.NullOr(Schema.String).annotate({ description: "The values' HealthKit unit." }),
  statistic: Schema.String.annotate({
    description: "The statistic: sum, average, minimum or maximum.",
  }),
  value: Schema.NullOr(Schema.Finite).annotate({
    description: "The statistic over the whole period, or null without data.",
  }),
  buckets: Schema.Array(HealthMetricBucket).annotate({
    description: "The period's hours, days, weeks or months, oldest first.",
  }),
});

export const Metric = readOnly(
  Tool.make("metric", {
    description:
      "A quantity type's statistic over a period, overall and per hour, day, week or month, " +
      "computed as Health does: totals of types that add up come from the iPhone's own " +
      "statistics (so iPhone and Watch steps aren't counted twice), and averages follow the " +
      "type's style (heart rate is weighted by time), with each value of a series (an Apple " +
      "Watch's heart rate in a workout) counted at its own time. Prefer this to samples.",
    parameters: Schema.Struct({
      type: healthType,
      range,
      statistic: Schema.optionalKey(
        Schema.Literals(["sum", "average", "minimum", "maximum"]).annotate({
          description:
            "Defaults to sum for types that add up (steps, energy), and average for others.",
        }),
      ),
      date,
      timeZone,
    }),
    success: HealthMetricResult,
    failure: HealthToolError,
  }),
  "Health Metric",
);

// -------------------------------------------------------------------------------------------------
// samples
// -------------------------------------------------------------------------------------------------

/** The most samples one call returns. */
export const samplesLimit = 500;

/** A field a sample has only when HealthKit says (851-4166): absent, never null. */
const when = <S extends Schema.Top>(schema: S, description: string) =>
  Schema.optionalKey(schema.annotate({ description }));

/** An enum-like field: HealthKit's case name, without its prefix, as a plain string. */
const caseName = (description: string) => when(Schema.String, description);

const recordedTimeZone = when(
  Schema.String,
  "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. " +
    "Left out when it has none, or one that isn't an IANA name. Its other times stay in the " +
    "output's `timeZone`, so they compare across records.",
);

/** A time on the clock of the zone a record was recorded in (851-4177). */
const recordedClock = (what: string) =>
  when(
    Schema.String,
    `${what}, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. ` +
      "2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with " +
      "recordedTimeZone.",
  );

/**
 * A record's recorded times (851-4177, `docs/decisions/health.md` › Recorded time zones): the zone
 * it was recorded in, and its start and end on that zone's clock, when it has one.
 */
const recordedTimeFields = {
  recordedTimeZone,
  recordedStart: recordedClock("When it starts"),
  recordedEnd: recordedClock("When it ends"),
};

/** The recorded zone, and the time on its clock, of a record of one time. */
const recordedMomentFields = {
  recordedTimeZone,
  recordedTime: recordedClock("Its time"),
};

export const HealthSampleDevice = Schema.Struct({
  name: when(Schema.String, "The device's name, e.g. Apple Watch."),
  manufacturer: when(Schema.String, "Who made it, e.g. Apple Inc."),
  model: when(Schema.String, "Its model, e.g. Watch."),
  hardwareVersion: when(Schema.String, "Its hardware version, e.g. Watch7,1."),
  firmwareVersion: when(Schema.String, "Its firmware version."),
  softwareVersion: when(Schema.String, "Its software version, e.g. 26.1."),
}).annotate({ identifier: "HealthSampleDevice" });

export const HealthCorrelatedValue = Schema.Struct({
  type: healthType,
  value: Schema.NullOr(Schema.Finite).annotate({ description: "Its value, in `unit`." }),
  unit: Schema.NullOr(Schema.String),
}).annotate({ identifier: "HealthCorrelatedValue" });

/**
 * Where samples came from (851-4166): the app or device, its version, and the device that
 * measured them. A page lists each once, in `sources`, and each sample says which is its.
 */
export const HealthSampleSource = Schema.Struct({
  name: Schema.String.annotate({
    description: "The app or device that saved it, as the sample's `source`.",
  }),
  bundleId: when(
    Schema.String,
    "The bundle ID of the app that saved it, e.g. com.dexcom.G7. Left out for Apple devices' " +
      "own (com.apple.health.<UUID>), whose UUID identifies the device.",
  ),
  version: when(Schema.String, "The version of the app, or the OS, that saved it."),
  productType: when(
    Schema.String,
    "The hardware the app that saved it ran on, e.g. iPhone17,1 or Watch7,1.",
  ),
  operatingSystemVersion: when(Schema.String, "The OS version it ran on, e.g. 26.1.0."),
  device: when(
    HealthSampleDevice,
    "The device that measured it (HKDevice, else the HKMetadataKeyDeviceName and " +
      "…ManufacturerName metadata), with only the properties it has.",
  ),
}).annotate({ identifier: "HealthSampleSource" });

/**
 * What a sample's metadata says (851-4166): only the keys lil health keeps (851-4152), each read
 * into a plain field. Every one is left out when HealthKit doesn't have it, so most samples have
 * only a few.
 */
export const sampleDetailFields = {
  userEntered: when(
    Schema.Boolean,
    "True if someone entered it by hand, e.g. in the Health app (HKMetadataKeyWasUserEntered).",
  ),
  values: when(
    Schema.Array(HealthCorrelatedValue),
    "For a correlation (blood pressure, food): the samples it groups, by type, e.g. systolic " +
      "and diastolic, or each nutrient of a food.",
  ),
  food: when(Schema.String, "A food's name (HKMetadataKeyFoodType)."),
  motionContext: caseName(
    "Heart rate: sedentary (still) or active (moving or working out) " +
      "(HKMetadataKeyHeartRateMotionContext).",
  ),
  userMotionContext: caseName(
    "stationary or active, how the person was moving (HKMetadataKeyUserMotionContext).",
  ),
  sensorLocation: caseName(
    "Where it was measured: for heart rate chest, wrist, finger, hand, earLobe, foot or other " +
      "(HKMetadataKeyHeartRateSensorLocation); for body temperature armpit, body, ear, finger, " +
      "gastroIntestinal, mouth, rectum, toe, earDrum, temporalArtery, forehead or other " +
      "(HKMetadataKeyBodyTemperatureSensorLocation).",
  ),
  mealTime: caseName(
    "Blood glucose: preprandial (before a meal) or postprandial (after one) " +
      "(HKMetadataKeyBloodGlucoseMealTime).",
  ),
  insulinDeliveryReason: caseName("Insulin: basal or bolus (HKMetadataKeyInsulinDeliveryReason)."),
  vo2MaxTestType: caseName(
    "Cardio fitness: how it was measured, maxExercise, predictionSubMaxExercise, " +
      "predictionNonExercise or predictionStepTest (HKMetadataKeyVO2MaxTestType). Apple " +
      "Watch's estimates are predictionSubMaxExercise.",
  ),
  vo2Max: when(
    Schema.Finite,
    "A low cardio fitness event's VO2 max, in mL/(kg·min) (HKMetadataKeyVO2MaxValue).",
  ),
  lowCardioFitnessThreshold: when(
    Schema.Finite,
    "The VO2 max under which cardio fitness counted as low, in mL/(kg·min) " +
      "(HKMetadataKeyLowCardioFitnessEventThreshold).",
  ),
  heartRateEventThreshold: when(
    Schema.Finite,
    "A high or low heart rate event's threshold, in beats per minute " +
      "(HKMetadataKeyHeartRateEventThreshold).",
  ),
  heartRateRecoveryTestType: caseName(
    "Cardio recovery: maxExercise, predictionSubMaxExercise, predictionNonExercise or " +
      "stepTest (HKMetadataKeyHeartRateRecoveryTestType).",
  ),
  heartRateRecoveryActivity: when(
    Schema.String,
    "Cardio recovery: the workout activity before it, e.g. Running " +
      "(HKMetadataKeyHeartRateRecoveryActivityType).",
  ),
  heartRateRecoveryActivityDuration: when(
    Schema.Finite,
    "Cardio recovery: seconds of that activity (HKMetadataKeyHeartRateRecoveryActivityDuration).",
  ),
  maxObservedRecoveryHeartRate: when(
    Schema.Finite,
    "Cardio recovery: the highest heart rate seen, in beats per minute " +
      "(HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate).",
  ),
  audioExposureLevel: when(
    Schema.Finite,
    "A noise or headphone audio event's level, in dB(A) SPL (HKMetadataKeyAudioExposureLevel).",
  ),
  audioExposureDuration: when(
    Schema.Finite,
    "Seconds of headphone audio it covers (HKMetadataKeyAudioExposureDuration).",
  ),
  headphoneGain: when(
    Schema.Finite,
    "A headphone audio event's gain, in dB(A) SPL (HKMetadataKeyHeadphoneGain).",
  ),
  physicalEffortEstimationType: caseName(
    "Physical effort: activityLookup or deviceSensed (HKMetadataKeyPhysicalEffortEstimationType).",
  ),
  activity: when(
    Schema.String,
    "The workout activity it was during, e.g. Hiking (HKMetadataKeyActivityType).",
  ),
  placementSide: caseName(
    "Where the iPhone was carried while walking: left, right or central " +
      "(HKMetadataKeyDevicePlacementSide).",
  ),
  deviceCalibrated: when(
    Schema.Boolean,
    "Whether the device had enough calibration data for it (HKMetadataKeyAppleDeviceCalibrated).",
  ),
  algorithmVersion: when(
    Schema.Finite,
    "The version of the algorithm that estimated it (HKMetadataKeyAlgorithmVersion).",
  ),
  earliestDataUsedForEstimate: when(
    LocalTime,
    "How far back the estimate's data goes (HKMetadataKeyDateOfEarliestDataUsedForEstimate).",
  ),
  clampedToLowerBound: when(
    Schema.Boolean,
    "True if the value was raised to the lowest the sensor reports " +
      "(HKMetadataKeyQuantityClampedToLowerBound).",
  ),
  clampedToUpperBound: when(
    Schema.Boolean,
    "True if the value was lowered to the highest the sensor reports " +
      "(HKMetadataKeyQuantityClampedToUpperBound).",
  ),
  referenceRangeLowerLimit: when(
    Schema.Finite,
    "A lab result's reference range's lower limit (HKMetadataKeyReferenceRangeLowerLimit).",
  ),
  referenceRangeUpperLimit: when(
    Schema.Finite,
    "A lab result's reference range's upper limit (HKMetadataKeyReferenceRangeUpperLimit).",
  ),
  takenInLab: when(Schema.Boolean, "Whether it was taken in a lab (HKMetadataKeyWasTakenInLab)."),
  waterSalinity: caseName(
    "Underwater depth or water temperature: freshWater or saltWater " +
      "(HKMetadataKeyWaterSalinity).",
  ),
  maximumLightIntensity: when(
    Schema.Finite,
    "Time in daylight: the brightest light, in lux (HKMetadataKeyMaximumLightIntensity).",
  ),
  menstrualCycleStart: when(
    Schema.Boolean,
    "Menstrual flow: whether it started a cycle (HKMetadataKeyMenstrualCycleStart).",
  ),
  protectionUsed: when(
    Schema.Boolean,
    "Sexual activity: whether protection was used (HKMetadataKeySexualActivityProtectionUsed).",
  ),
};

/**
 * A quantity series (851-4171): a sample of many values, such as a Watch's heart rate every few
 * seconds in a workout. `samples` shows its count and a discrete series' summary, or, with
 * `seriesValues`, each value as an item of its own, saying which it is.
 */
export const HealthSampleSeries = Schema.Struct({
  count: Schema.Int.annotate({ description: "How many values the series has." }),
  index: when(
    Schema.Int,
    "With seriesValues: which of the series' values this item is, from 0, the earliest. Left out " +
      "for a series whose values weren't uploaded (more than 20,000), listed as one sample.",
  ),
  minimum: when(Schema.Finite, "A discrete series' lowest value (heart rate), in `unit`."),
  maximum: when(Schema.Finite, "Its highest value."),
  mostRecent: when(Schema.Finite, "Its last value."),
  mostRecentStart: when(LocalTime, "When its last value starts."),
  mostRecentEnd: when(LocalTime, "When its last value ends."),
}).annotate({ identifier: "HealthSampleSeries" });

export const HealthSampleItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the sample." }),
  start: LocalTime,
  end: LocalTime,
  ...recordedTimeFields,
  value: Schema.NullOr(Schema.Finite).annotate({
    description:
      "A quantity's value, in `unit`: for a series, HealthKit's for all of it, its total or its " +
      "time-weighted average. Null for category types and correlations.",
  }),
  unit: Schema.NullOr(Schema.String),
  categoryValue: Schema.NullOr(Schema.Int).annotate({
    description:
      "A category sample's HealthKit value (HKCategoryValue…). Null for quantities and " +
      "correlations.",
  }),
  source: Schema.String.annotate({
    description: "The app or device that recorded it, e.g. an Apple Watch's name.",
  }),
  sourceIndex: Schema.Int.annotate({
    description: "Its entry in `sources`: the app, its version and the device, from 0.",
  }),
  series: when(
    HealthSampleSeries,
    "Only for a quantity series, a sample of many values: its count and summary, or which of its " +
      "values this item is.",
  ),
  ...sampleDetailFields,
}).annotate({ identifier: "HealthSampleItem" });

export const HealthSamplesResult = Schema.Struct({
  ...periodFields,
  type: healthType,
  samples: Schema.Array(HealthSampleItem).annotate({
    description: "Samples that start in the period, newest first.",
  }),
  sources: Schema.Array(HealthSampleSource).annotate({
    description:
      "Where this page's samples came from, each app and device once, in the order they first " +
      "appear: a sample's sourceIndex is its entry.",
  }),
  nextCursor: Schema.NullOr(Schema.String).annotate({
    description: "Pass it as `cursor` for the next, older page; null on the last page.",
  }),
});

export const Samples = readOnly(
  Tool.make("samples", {
    description:
      "Individual samples of a quantity, category or correlation type (blood pressure, food) " +
      "in a period, newest first, a page at a time, each with its source app and device (listed " +
      "once a page, in sources) and what its metadata says (how and where it was measured, whether it was entered by hand), " +
      "fields only when HealthKit has them. A type can have many thousands of samples a day: " +
      "use metric for totals and trends, and this only to look at particular readings. A " +
      "series (an Apple Watch's heart rate in a workout) is one sample with its count and " +
      "summary, or its values with seriesValues. " +
      "Workouts, Activity rings, State of Mind, GAD-7 and PHQ-9 assessments, medications, " +
      "their doses and health details have their own tools.",
    parameters: Schema.Struct({
      type: healthType,
      range,
      date,
      timeZone,
      cursor: Schema.optionalKey(
        Schema.String.annotate({ description: "The previous page's nextCursor." }),
      ),
      limit: Schema.optionalKey(
        Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: samplesLimit })).annotate({
          description: `Samples per page, at most ${samplesLimit}. Defaults to 100.`,
        }),
      ),
      seriesValues: Schema.optionalKey(
        Schema.Boolean.annotate({
          description:
            "List each quantity series' values, newest first, in place of the series, each " +
            "counting toward the limit; a page can end inside a series. Defaults to false.",
        }),
      ),
    }),
    success: HealthSamplesResult,
    failure: HealthToolError,
  }),
  "Health Samples",
);

// -------------------------------------------------------------------------------------------------
// workouts
// -------------------------------------------------------------------------------------------------

/** The most workouts one call returns. */
export const workoutsLimit = 100;

const workoutIndoor = Schema.NullOr(Schema.Boolean).annotate({
  description:
    "Whether it was indoors (a treadmill run, an indoor ride, a pool swim) rather than " +
    "outdoors, as the app that recorded it says (HKMetadataKeyIndoorWorkout) or, failing " +
    "that, as it was set up (its workout configuration's location), or null if neither says.",
});

const swimmingLocation = Schema.NullOr(Schema.String).annotate({
  description:
    "For swims: pool or openWater (HKMetadataKeySwimmingLocationType, else its workout " +
    "configuration's), or null if neither says.",
});

export const HealthWorkoutActivityItem = Schema.Struct({
  activityType: Schema.Int.annotate({ description: "HKWorkoutActivityType's raw value." }),
  activity: Schema.String.annotate({ description: "The activity's name, e.g. Swimming." }),
  start: LocalTime,
  end: Schema.NullOr(LocalTime),
  duration: Schema.Finite.annotate({ description: "Seconds of activity, excluding pauses." }),
  indoor: workoutIndoor,
  swimmingLocation,
}).annotate({ identifier: "HealthWorkoutActivityItem" });

export const HealthWorkoutItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the workout." }),
  activityType: Schema.Int.annotate({
    description: "HKWorkoutActivityType's raw value, e.g. 37 for running.",
  }),
  activity: Schema.String.annotate({ description: "The activity's name, e.g. Running." }),
  name: Schema.NullOr(Schema.String).annotate({
    description:
      "The workout's own name, from the app that recorded it (HKMetadataKeyWorkoutBrandName), " +
      "else the name of the planned workout it followed (a custom or swim-bike-run workout " +
      "made in an app with WorkoutKit). Usually null: the Workout app doesn't name its own.",
  }),
  start: LocalTime,
  end: LocalTime,
  ...recordedTimeFields,
  duration: Schema.Finite.annotate({ description: "Seconds of activity, excluding pauses." }),
  activeEnergy: Schema.NullOr(Schema.Finite).annotate({ description: "Kilocalories." }),
  distance: Schema.NullOr(Schema.Finite).annotate({ description: "Meters." }),
  averageHeartRate: Schema.NullOr(Schema.Finite).annotate({
    description: "Beats per minute.",
  }),
  elevationAscended: Schema.NullOr(Schema.Finite).annotate({
    description:
      "Meters climbed, if the app that recorded it says (HKMetadataKeyElevationAscended).",
  }),
  indoor: workoutIndoor.annotate({
    description:
      "Whether it was indoors (a treadmill run, an indoor ride, a pool swim) rather than " +
      "outdoors, as the app that recorded it says (HKMetadataKeyIndoorWorkout), or as its " +
      "activities say (their metadata, else how each was set up: its workout configuration's " +
      "location), if they agree. Null if none says: then hasRoute is the best hint.",
  }),
  swimmingLocation: swimmingLocation.annotate({
    description:
      "For swims: pool or openWater (HKMetadataKeySwimmingLocationType), as the workout or " +
      "its activities say (their metadata, else their workout configurations), if they " +
      "agree, or null if none says.",
  }),
  hasRoute: Schema.Boolean.annotate({
    description:
      "Whether it has a GPS route: one HealthKit linked to it or, failing that, one linked to " +
      "no workout that was recorded during it. Outdoor runs, walks and rides recorded on an " +
      "iPhone or Apple Watch have one; treadmill runs and other indoor workouts don't. " +
      "workout_route reads it, by the workout's ID.",
  }),
  source: Schema.String.annotate({ description: "The app or device that recorded it." }),
  activities: Schema.Array(HealthWorkoutActivityItem).annotate({
    description:
      "A multisport workout's activities (e.g. swim, transition, bike, run), in order. Empty " +
      "for a workout of one activity.",
  }),
}).annotate({ identifier: "HealthWorkoutItem" });

export const HealthWorkoutsResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({ description: "Workouts in the period, all of them." }),
  duration: Schema.Finite.annotate({ description: "Their total duration, in seconds." }),
  workouts: Schema.Array(HealthWorkoutItem).annotate({
    description: `The workouts, newest first, at most ${workoutsLimit}.`,
  }),
});

export const Workouts = readOnly(
  Tool.make("workouts", {
    description:
      "Workouts that started in a period, newest first, with their activity and name, " +
      "duration, energy, distance, average heart rate and elevation, whether they were " +
      "indoors and had a GPS route (to tell a treadmill run from an outdoor one), and the " +
      "period's count and total time. For one workout's other statistics, laps, segments, " +
      "pauses, weather and multisport legs, call workout with its id.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthWorkoutsResult,
    failure: HealthToolError,
  }),
  "Health Workouts",
);

// -------------------------------------------------------------------------------------------------
// workout
// -------------------------------------------------------------------------------------------------

/** The most pauses, laps or segments `workout` lists of each. */
export const workoutEventsLimit = 300;

/**
 * Quantities read from metadata, which iPhones store whole since 851-4150, and before as text with
 * 6 significant digits ("4250 cm"): an updated iPhone uploads its workouts again whole, but until
 * then (or from an iPhone that isn't updated) they're rounded to that. One in a unit the tools
 * don't know is null.
 */
const fromMetadata = (key: string, what: string) =>
  `${what}, if the app that recorded it says (${key}). To 12 significant digits, or 6 if an ` +
  "older lil health uploaded it.";

/** What a workout's, or one of its activities', metadata says beyond where it was. */
const workoutMetadataFields = {
  elevationDescended: Schema.NullOr(Schema.Finite).annotate({
    description: fromMetadata("HKMetadataKeyElevationDescended", "Meters descended"),
  }),
  averageSpeed: Schema.NullOr(Schema.Finite).annotate({
    description: fromMetadata("HKMetadataKeyAverageSpeed", "Average speed, in meters per second"),
  }),
  maximumSpeed: Schema.NullOr(Schema.Finite).annotate({
    description: fromMetadata("HKMetadataKeyMaximumSpeed", "Top speed, in meters per second"),
  }),
  averageMETs: Schema.NullOr(Schema.Finite).annotate({
    description: fromMetadata(
      "HKMetadataKeyAverageMETs",
      "Average intensity over the whole workout, in METs (kcal/hr·kg)",
    ),
  }),
  lapLength: Schema.NullOr(Schema.Finite).annotate({
    description: fromMetadata(
      "HKMetadataKeyLapLength",
      "For pool swims: the pool's length, in meters (25 yd is 22.86)",
    ),
  }),
  swolf: Schema.NullOr(Schema.Finite).annotate({
    description:
      "For swims: the SWOLF score (strokes plus seconds per length; lower is more efficient), " +
      "if the app that recorded it says (HKMetadataKeySWOLFScore).",
  }),
};

export const HealthWorkoutStatistic = Schema.Struct({
  type: healthType.annotate({
    description: "The quantity type, e.g. HKQuantityTypeIdentifierHeartRate.",
  }),
  name: Schema.NullOr(Schema.String).annotate({
    description: "The name Health shows for it, e.g. Heart Rate.",
  }),
  unit: Schema.String.annotate({
    description: "The HealthKit unit of its values, e.g. count/min, W, m or kcal.",
  }),
  sum: Schema.NullOr(Schema.Finite).annotate({
    description: "For types that add up (energy, distance, steps, strokes): the total.",
  }),
  average: Schema.NullOr(Schema.Finite).annotate({
    description: "For other types (heart rate, power, cadence, speed): the average.",
  }),
  minimum: Schema.NullOr(Schema.Finite).annotate({ description: "The lowest reading." }),
  maximum: Schema.NullOr(Schema.Finite).annotate({ description: "The highest reading." }),
  mostRecent: Schema.NullOr(Schema.Finite).annotate({ description: "The last reading." }),
}).annotate({ identifier: "HealthWorkoutStatistic" });

const workoutStatistics = Schema.Array(HealthWorkoutStatistic).annotate({
  description:
    "Every statistic HealthKit computed over it, one per quantity type, by type: energy, " +
    "distance, heart rate (average, minimum, maximum), power, cadence, speed, stride length, " +
    "ground contact time, vertical oscillation, swimming strokes, flights climbed… whatever " +
    "was recorded. Null where HealthKit gives none.",
});

export const HealthWorkoutPause = Schema.Struct({
  start: LocalTime,
  end: LocalTime.annotate({ description: "When it resumed, or the workout's end." }),
  duration: Schema.Finite.annotate({ description: "Seconds." }),
}).annotate({ identifier: "HealthWorkoutPause" });

export const HealthWorkoutInterval = Schema.Struct({
  start: LocalTime,
  end: LocalTime,
  duration: Schema.Finite.annotate({ description: "Seconds, from start to end." }),
  strokeStyle: Schema.NullOr(Schema.String).annotate({
    description:
      "For swims: the main stroke (HKMetadataKeySwimmingStrokeStyle): mixed, freestyle, " +
      "backstroke, breaststroke, butterfly or kickboard, or null if it doesn't say.",
  }),
  swolf: workoutMetadataFields.swolf,
  lapLength: workoutMetadataFields.lapLength,
  averageSpeed: workoutMetadataFields.averageSpeed,
  maximumSpeed: workoutMetadataFields.maximumSpeed,
}).annotate({ identifier: "HealthWorkoutInterval" });

/** Unnamed: a nullable schema in the spec can't be a reference (`normalize` in `OpenApiSpec.ts`). */
export const HealthWorkoutEffortScore = Schema.Struct({
  score: Schema.Finite.annotate({
    description:
      "How hard it was, from 1 to 10, as Health rates it: 1 to 3 Easy, 4 to 6 Moderate, 7 and " +
      "8 Hard, 9 and 10 All Out.",
  }),
  estimated: Schema.Boolean.annotate({
    description:
      "Whether it's Apple Watch's estimate (HKQuantityTypeIdentifierEstimatedWorkoutEffortScore) " +
      "rather than a score the person rated (HKQuantityTypeIdentifierWorkoutEffortScore).",
  }),
});

/** A workout's, or one of its legs', effort score. */
const workoutEffort = (what: string) =>
  Schema.NullOr(HealthWorkoutEffortScore).annotate({
    description:
      `${what} effort score: the one HealthKit finds most relevant among those related to it ` +
      "(HKWorkoutEffortRelationship), else, if that hasn't synced, the latest one the person " +
      "rated, else Apple Watch's latest estimate. People often rate a workout after it ends. " +
      "Null when it has none, or when linksRead is false and lil health doesn't know.",
  });

export const HealthWorkoutLeg = Schema.Struct({
  ...HealthWorkoutActivityItem.fields,
  elevationAscended: Schema.NullOr(Schema.Finite).annotate({
    description: fromMetadata("HKMetadataKeyElevationAscended", "Meters climbed"),
  }),
  ...workoutMetadataFields,
  effort: workoutEffort("The leg's own"),
  statistics: workoutStatistics.annotate({ description: "The leg's own statistics." }),
}).annotate({ identifier: "HealthWorkoutLeg" });

export const HealthWorkoutDetail = Schema.Struct({
  ...HealthWorkoutItem.fields,
  elevationAscended: HealthWorkoutItem.fields.elevationAscended.annotate({
    description: fromMetadata("HKMetadataKeyElevationAscended", "Meters climbed"),
  }),
  ...workoutMetadataFields,
  weatherCondition: Schema.NullOr(Schema.String).annotate({
    description:
      "The weather (HKMetadataKeyWeatherCondition), as HKWeatherCondition names it, e.g. " +
      "clear, partlyCloudy, showers or snow, or null if it doesn't say.",
  }),
  weatherTemperature: Schema.NullOr(Schema.Finite).annotate({
    description: fromMetadata("HKMetadataKeyWeatherTemperature", "The temperature, in °C"),
  }),
  weatherHumidity: Schema.NullOr(Schema.Finite).annotate({
    description:
      "Relative humidity, in percent from 0 to 100 (HKMetadataKeyWeatherHumidity). Apple's " +
      "Workout app writes it 100 times too large (72% as 7200 %), so a value over 100 is " +
      "divided by 100. To 12 significant digits, or 6 if an older lil health uploaded it.",
  }),
  linksRead: Schema.Boolean.annotate({
    description:
      "Whether lil health has read what HealthKit links to the workout: its effort scores, " +
      "and the samples recorded with it. False for a workout an older lil health on the " +
      "iPhone uploaded, until an updated one reads its links. While it's false, a null effort " +
      "means lil health doesn't know the score, not that there's none.",
  }),
  effort: workoutEffort("The workout's"),
  statistics: workoutStatistics,
  pauseCount: Schema.Int.annotate({ description: "How many times it was paused." }),
  pauses: Schema.Array(HealthWorkoutPause).annotate({
    description:
      "When it was paused, by the person or automatically (auto-pause), from each pause to " +
      `the resume after it, in order, at most ${workoutEventsLimit}. duration leaves them out.`,
  }),
  lapCount: Schema.Int,
  laps: Schema.Array(HealthWorkoutInterval).annotate({
    description:
      `Its laps (HKWorkoutEventTypeLap), in order, at most ${workoutEventsLimit}: a pool ` +
      "swim's lengths, with each one's stroke and SWOLF, or laps marked in an app.",
  }),
  segmentCount: Schema.Int,
  segments: Schema.Array(HealthWorkoutInterval).annotate({
    description:
      `Its segments (HKWorkoutEventTypeSegment), in order, at most ${workoutEventsLimit}: ` +
      "splits, intervals or sets, as the app that recorded it marked them.",
  }),
  activities: Schema.Array(HealthWorkoutLeg).annotate({
    description:
      "A multisport workout's legs (e.g. swim, transition, bike, run), in order, each with " +
      "its own statistics and effort score. Empty for a workout of one activity, whose " +
      "statistics and score are the workout's.",
  }),
}).annotate({ identifier: "HealthWorkoutDetail" });

export const HealthWorkoutResult = Schema.Struct({
  timeZone: usedTimeZone,
  workout: HealthWorkoutDetail,
});

export const Workout = readOnly(
  Tool.make("workout", {
    description:
      "One workout in full, by the ID workouts gives: everything workouts says, plus every " +
      "statistic HealthKit computed (maximum and minimum heart rate, power, cadence, stride " +
      "length, swimming strokes…), descent, speeds, METs, the weather, SWOLF and pool length, " +
      "its pauses, laps (with each length's stroke and SWOLF) and segments, its effort score " +
      "(rated or Apple Watch's estimate), and a multisport workout's legs with their own " +
      "statistics and scores. Values from the workout's metadata have 12 " +
      "significant digits, or 6 if an older lil health uploaded it.",
    parameters: Schema.Struct({
      id: Schema.String.annotate({ description: "The workout's ID, from workouts." }),
      timeZone,
    }),
    success: HealthWorkoutResult,
    failure: HealthToolError,
  }),
  "Health Workout",
);

// -------------------------------------------------------------------------------------------------
// workout_routes, workout_route and workout_route_points
// -------------------------------------------------------------------------------------------------

/** The most routes `workout_routes` lists. */
export const workoutRoutesLimit = 100;
/** The most points `workout_route`'s simplified shape keeps. */
export const routeShapeLimit = 500;
/** The simplified shape's first tolerance, in meters, doubled until it keeps few enough points. */
export const routeShapeTolerance = 5;
/** The most points `workout_route_points` returns, and how many it returns by default. */
export const routePointsLimit = 1000;
export const routePointsDefaultLimit = 500;

const routeOf =
  "By a workout's ID (from workouts, when hasRoute is true) or a route's (from workout_routes). " +
  "A workout's route is the one HealthKit linked to it or, failing that, one linked to no " +
  "workout that was recorded during it.";

const routeIdParameter = Schema.String.annotate({
  description: "A workout's ID, from workouts, or a route's, from workout_routes.",
});

const routeFloat =
  "Stored as a 32-bit float, so rounded to 2 decimal places, or null if the device didn't know.";

export const HealthWorkoutRouteItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the route." }),
  workout: Schema.NullOr(Schema.String).annotate({
    description:
      "The ID of the workout HealthKit linked it to, or null if it links none: then " +
      "workout_route still finds it by the ID of a workout it was recorded during.",
  }),
  start: LocalTime,
  end: LocalTime,
  ...recordedTimeFields,
  duration: Schema.Finite.annotate({ description: "Seconds, from start to end." }),
  pointCount: Schema.Int.annotate({ description: "How many GPS points it has." }),
  source: Schema.String.annotate({ description: "The app or device that recorded it." }),
}).annotate({ identifier: "HealthWorkoutRouteItem" });

export const HealthWorkoutRoutesResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({ description: "Routes that start in the period, all of them." }),
  routes: Schema.Array(HealthWorkoutRouteItem).annotate({
    description: `The routes, newest first, at most ${workoutRoutesLimit}.`,
  }),
});

export const WorkoutRoutes = readOnly(
  Tool.make("workout_routes", {
    description:
      "GPS routes that started in a period, newest first, each with the workout it belongs to: " +
      "outdoor workouts' routes, and any recorded without one (by another app, or whose " +
      "workout was deleted). workouts already says which workouts have one (hasRoute). For a " +
      "route's distance, elevation and shape, call workout_route.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthWorkoutRoutesResult,
    failure: HealthToolError,
  }),
  "Health Workout Routes",
);

/** Inline, not named: the spec can't name a schema that's nullable (`OpenApiSpec.ts`). */
const HealthRouteCoordinate = Schema.Struct({
  latitude: Schema.Finite,
  longitude: Schema.Finite,
});

const HealthRouteBounds = Schema.Struct({
  south: Schema.Finite.annotate({ description: "The lowest latitude, in degrees." }),
  west: Schema.Finite.annotate({ description: "The lowest longitude, in degrees." }),
  north: Schema.Finite.annotate({ description: "The highest latitude, in degrees." }),
  east: Schema.Finite.annotate({ description: "The highest longitude, in degrees." }),
});

export const HealthRouteShapePoint = Schema.Struct({
  time: LocalTime,
  latitude: Schema.Finite.annotate({ description: "Degrees, to 5 decimal places." }),
  longitude: Schema.Finite.annotate({ description: "Degrees, to 5 decimal places." }),
  altitude: Schema.NullOr(Schema.Finite).annotate({
    description: `Meters above sea level. ${routeFloat}`,
  }),
}).annotate({ identifier: "HealthRouteShapePoint" });

export const HealthRouteShape = Schema.Struct({
  tolerance: Schema.Finite.annotate({
    description:
      "Meters: no point of the route is further than this from the line through points. " +
      `${routeShapeTolerance} m, doubled until it keeps at most ${routeShapeLimit} points.`,
  }),
  pointCount: Schema.Int.annotate({ description: "How many points it kept." }),
  points: Schema.Array(HealthRouteShapePoint).annotate({
    description: "The points it kept, in order, the first and last included.",
  }),
}).annotate({ identifier: "HealthRouteShape" });

export const HealthWorkoutRouteDetail = Schema.Struct({
  ...HealthWorkoutRouteItem.fields,
  distance: Schema.Finite.annotate({
    description:
      "Meters along its points, from each to the next on the Earth's surface. The workout's " +
      "own distance, which the Watch also measures by motion, may differ a little.",
  }),
  elevationGain: Schema.NullOr(Schema.Finite).annotate({
    description:
      "Meters climbed: every rise from one point to the next, among the points with a known " +
      "altitude, to 2 decimal places. From GPS, so noisier, and usually higher, than the " +
      "workout's elevationAscended, which the barometer measures. Null without two such points.",
  }),
  elevationLoss: Schema.NullOr(Schema.Finite).annotate({
    description: "Meters descended, as elevationGain counts climbs.",
  }),
  bounds: Schema.NullOr(HealthRouteBounds).annotate({
    description: "The box its points fit in, to 5 decimal places (about a meter).",
  }),
  startArea: Schema.NullOr(HealthRouteCoordinate).annotate({
    description: "About where it starts: its first point, to 3 decimal places (about 100 m).",
  }),
  endArea: Schema.NullOr(HealthRouteCoordinate).annotate({
    description: "About where it ends: its last point, to 3 decimal places (about 100 m).",
  }),
  simplified: HealthRouteShape.annotate({
    description:
      "Its shape, simplified (Ramer-Douglas-Peucker): enough to draw it, or to tell where it " +
      "went and when.",
  }),
}).annotate({ identifier: "HealthWorkoutRouteDetail" });

export const HealthWorkoutRouteResult = Schema.Struct({
  timeZone: usedTimeZone,
  route: HealthWorkoutRouteDetail,
});

export const WorkoutRoute = readOnly(
  Tool.make("workout_route", {
    description:
      "One GPS route in summary: its distance, elevation gain and loss, bounds, where it " +
      `starts and ends, and its shape as a simplified line of at most ${routeShapeLimit} ` +
      `points, with the tolerance used. ${routeOf} Its every point, with speed, course and ` +
      "accuracy, comes from workout_route_points, a page at a time: ask for them only when " +
      "the shape isn't enough. Routes are precise locations.",
    parameters: Schema.Struct({ id: routeIdParameter, timeZone }),
    success: HealthWorkoutRouteResult,
    failure: HealthToolError,
  }),
  "Health Workout Route",
);

export const HealthRoutePoint = Schema.Struct({
  time: LocalTime,
  latitude: Schema.Finite.annotate({ description: "Degrees." }),
  longitude: Schema.Finite.annotate({ description: "Degrees." }),
  altitude: Schema.NullOr(Schema.Finite).annotate({
    description: `Meters above sea level. ${routeFloat}`,
  }),
  horizontalAccuracy: Schema.NullOr(Schema.Finite).annotate({
    description: `Meters: the radius the true position is within. ${routeFloat}`,
  }),
  verticalAccuracy: Schema.NullOr(Schema.Finite).annotate({
    description: `Meters: how far the true altitude may be. ${routeFloat}`,
  }),
  speed: Schema.NullOr(Schema.Finite).annotate({
    description: `Meters per second. ${routeFloat}`,
  }),
  course: Schema.NullOr(Schema.Finite).annotate({
    description: `Degrees from true north it was heading. ${routeFloat}`,
  }),
}).annotate({ identifier: "HealthRoutePoint" });

export const HealthWorkoutRoutePointsResult = Schema.Struct({
  timeZone: usedTimeZone,
  id: Schema.String.annotate({ description: "The route's ID." }),
  pointCount: Schema.Int.annotate({ description: "How many points the route has, all of them." }),
  points: Schema.Array(HealthRoutePoint).annotate({ description: "This page's points, in order." }),
  nextCursor: Schema.NullOr(Schema.String).annotate({
    description: "Pass it as `cursor` for the next page; null on the last page.",
  }),
});

export const WorkoutRoutePoints = readOnly(
  Tool.make("workout_route_points", {
    description:
      "A GPS route's points, in order, a page at a time: each one's time, latitude, longitude " +
      `and altitude, speed, course and accuracy. ${routeOf} A route has about a point a ` +
      "second, thousands an hour: call workout_route first, whose simplified shape is usually " +
      "enough, and this only to look at particular stretches. Routes are precise locations.",
    parameters: Schema.Struct({
      id: routeIdParameter,
      timeZone,
      cursor: Schema.optionalKey(
        Schema.String.annotate({ description: "The previous page's nextCursor." }),
      ),
      limit: Schema.optionalKey(
        Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: routePointsLimit })).annotate({
          description:
            `Points per page, at most ${routePointsLimit}. Defaults to ` +
            `${routePointsDefaultLimit}.`,
        }),
      ),
    }),
    success: HealthWorkoutRoutePointsResult,
    failure: HealthToolError,
  }),
  "Health Workout Route Points",
);

// -------------------------------------------------------------------------------------------------
// sleep
// -------------------------------------------------------------------------------------------------

export const HealthSleepNight = Schema.Struct({
  date: LocalDate.annotate({
    description:
      "The day the night ends on (sleep from 6 PM counts toward the next day), as YYYY-MM-DD, " +
      "on the clock of the zone it was slept in when it has one (recordedTimeZone), as Apple " +
      "Health dates it, else in the output's `timeZone`.",
  }),
  start: LocalTime.annotate({ description: "When the night's first sleep sample starts." }),
  end: LocalTime.annotate({ description: "When its last sleep sample ends." }),
  recordedTimeZone: when(
    Schema.String,
    "The time zone it was slept in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo: its last-ending " +
      "sample's that has one, so a night across a change of zone (a flight) is the zone it " +
      "ended in. Left out when none has one. start and end stay in the output's `timeZone`.",
  ),
  recordedStart: recordedClock("When it starts"),
  recordedEnd: recordedClock("When it ends"),
  inBed: Schema.Finite.annotate({ description: "Seconds in bed." }),
  asleep: Schema.Finite.annotate({ description: "Seconds asleep, in any stage." }),
  awake: Schema.Finite.annotate({ description: "Seconds awake during the night." }),
  core: Schema.Finite.annotate({ description: "Seconds of core sleep." }),
  deep: Schema.Finite.annotate({ description: "Seconds of deep sleep." }),
  rem: Schema.Finite.annotate({ description: "Seconds of REM sleep." }),
  unspecified: Schema.Finite.annotate({
    description: "Seconds asleep without a stage (sources that don't track stages).",
  }),
}).annotate({ identifier: "HealthSleepNight" });

export const HealthSleepResult = Schema.Struct({
  ...periodFields,
  nights: Schema.Array(HealthSleepNight).annotate({
    description:
      "Each night whose date is in the period, oldest first. A night slept in another zone is " +
      "dated by that zone's clock, so its start and end can fall outside the period.",
  }),
});

export const Sleep = readOnly(
  Tool.make("sleep", {
    description:
      "Sleep per night in a period: time in bed, asleep and awake, and the sleep stages (core, " +
      "deep, REM), from the person's sleep tracking. As in Apple Health, a night slept in " +
      "another time zone is dated by that zone's clock, and says which zone it was " +
      "(recordedTimeZone) and its times on that clock.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthSleepResult,
    failure: HealthToolError,
  }),
  "Health Sleep",
);

// -------------------------------------------------------------------------------------------------
// activity_rings
// -------------------------------------------------------------------------------------------------

const activityRing = (description: string, unit: string) =>
  Schema.Struct({
    value: Schema.Finite.annotate({ description: "How far it got, in `unit`." }),
    goal: Schema.Finite.annotate({ description: "The day's goal, in `unit`." }),
    unit: Schema.String.annotate({ description: unit }),
  }).annotate({ description });

export const HealthActivityDay = Schema.Struct({
  date: LocalDate.annotate({
    description:
      "The day, as the iPhone recorded it: a day in the iPhone's own time zone, whatever " +
      "`timeZone` is.",
  }),
  move: activityRing(
    "The Move ring: active energy, or minutes of movement for those who move by time " +
      "(children, or anyone who chose Move time).",
    "kcal, or min for Move time.",
  ),
  exercise: Schema.NullOr(
    activityRing(
      "The Exercise ring, in minutes of brisk activity, or null without an Exercise goal (no " +
        "Apple Watch).",
      "Always min.",
    ),
  ),
  stand: Schema.NullOr(
    activityRing(
      "The Stand ring, in hours with at least a minute of standing, or null without a Stand " +
        "goal (no Apple Watch).",
      "Always hr.",
    ),
  ),
  paused: Schema.Boolean.annotate({
    description: "Whether the person paused their rings that day, so its goals didn't count.",
  }),
}).annotate({ identifier: "HealthActivityDay" });

export const HealthActivityRingsResult = Schema.Struct({
  ...periodFields,
  days: Schema.Array(HealthActivityDay).annotate({
    description: "Each day of the period with rings, oldest first. Days without are left out.",
  }),
});

export const ActivityRings = readOnly(
  Tool.make("activity_rings", {
    description:
      "Activity rings per day in a period, as Fitness and lil health's Activity Rings show " +
      "them: Move (active kilocalories, or minutes in Move time), Exercise (minutes) and Stand " +
      "(hours), each with the day's value and goal, and whether the rings were paused. Exercise " +
      "and Stand are null without an Apple Watch. Days are the iPhone's own: the period's days " +
      "pick them by date, not shifted to `timeZone`. Without a `date`, the period ends today in " +
      "`timeZone`, so pass the person's time zone for their today.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthActivityRingsResult,
    failure: HealthToolError,
  }),
  "Health Activity Rings",
);

// -------------------------------------------------------------------------------------------------
// state_of_mind
// -------------------------------------------------------------------------------------------------

/** The most State of Mind logs one call returns. */
export const stateOfMindLimit = 500;

export const HealthStateOfMindItem = Schema.Struct({
  time: LocalTime.annotate({
    description:
      "When it was logged: a momentary emotion's moment, or for a daily mood, a time in the " +
      "day it describes.",
  }),
  ...recordedMomentFields,
  kind: Schema.String.annotate({
    description:
      "Momentary Emotion (how they felt right then) or Daily Mood (how they felt over the " +
      "day), or Unknown for one a later iOS adds.",
  }),
  valence: Schema.Finite.annotate({
    description: "How pleasant it felt, from -1 (very unpleasant) to 1 (very pleasant).",
  }),
  classification: Schema.String.annotate({
    description:
      "The valence as the person chose it: Very Unpleasant, Unpleasant, Slightly Unpleasant, " +
      "Neutral, Slightly Pleasant, Pleasant or Very Pleasant (Unknown for one a later iOS adds).",
  }),
  labels: Schema.Array(Schema.String).annotate({
    description:
      "The feelings that described it, e.g. Calm, Grateful or Stressed, in the order they were " +
      "logged. Empty if none.",
  }),
  associations: Schema.Array(Schema.String).annotate({
    description:
      "What it was about, e.g. Work, Family or Health, in the order they were logged. Empty if " +
      "none.",
  }),
  source: Schema.String.annotate({
    description: "The app or device it was logged in: Health, Mindfulness, or another app.",
  }),
}).annotate({ identifier: "HealthStateOfMindItem" });

export const HealthStateOfMindResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({ description: "State of Mind logs in the period, all of them." }),
  logs: Schema.Array(HealthStateOfMindItem).annotate({
    description: `The logs, newest first, at most ${stateOfMindLimit}.`,
  }),
});

export const StateOfMind = readOnly(
  Tool.make("state_of_mind", {
    description:
      "State of Mind logs in a period, newest first, as Health and lil health's State of " +
      "Mind show them: whether each was a momentary emotion or a daily mood, how pleasant it " +
      "felt (valence from -1 to 1, and its classification, e.g. Slightly Pleasant), the " +
      "feelings that described it (labels) and what it was about (associations), with the " +
      "period's count. People log them in the Health app, or in Mindfulness on Apple Watch.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthStateOfMindResult,
    failure: HealthToolError,
  }),
  "Health State of Mind",
);

// -------------------------------------------------------------------------------------------------
// assessments
// -------------------------------------------------------------------------------------------------

/** The most assessments one call returns. */
export const assessmentsLimit = 100;

export const HealthAssessmentItem = Schema.Struct({
  type: Schema.String.annotate({
    description:
      "HKScoredAssessmentTypeIdentifierGAD7 (anxiety) or HKScoredAssessmentTypeIdentifierPHQ9 " +
      "(depression).",
  }),
  name: Schema.String.annotate({
    description: "Its name in Health: Anxiety Risk (GAD-7) or Depression Risk (PHQ-9).",
  }),
  time: LocalTime.annotate({ description: "When it was taken." }),
  ...recordedMomentFields,
  score: Schema.Int.annotate({
    description: "The total of the answers' points, from 0 to maximumScore.",
  }),
  maximumScore: Schema.Int.annotate({
    description: "The highest score: 21 for GAD-7, 27 for PHQ-9 (3 points a question).",
  }),
  risk: Schema.String.annotate({
    description:
      "The risk Health gave the score. GAD-7: None to Minimal (0 to 4), Mild (5 to 9), " +
      "Moderate (10 to 14) or Severe (15 to 21). PHQ-9: None to Minimal (0 to 4), Mild (5 to " +
      "9), Moderate (10 to 14), Moderately Severe (15 to 19) or Severe (20 to 27). Unknown for " +
      "one a later iOS adds.",
  }),
  answers: Schema.Array(Schema.String).annotate({
    description:
      "Each question's answer, in the questionnaire's order (7 for GAD-7, 9 for PHQ-9), to " +
      "how often over the last two weeks: Not at all (0 points), Several days (1), More than " +
      "half the days (2) or Nearly every day (3). PHQ-9's 9th question, on thoughts of " +
      "self-harm, can be Prefer not to answer. Unknown for an answer a later iOS adds.",
  }),
}).annotate({ identifier: "HealthAssessmentItem" });

export const HealthAssessmentsResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({ description: "Assessments in the period, all of them." }),
  assessments: Schema.Array(HealthAssessmentItem).annotate({
    description: `The assessments, newest first, at most ${assessmentsLimit}.`,
  }),
});

export const Assessments = readOnly(
  Tool.make("assessments", {
    description:
      "GAD-7 (anxiety) and PHQ-9 (depression) questionnaires taken in a period, newest " +
      "first, as Health and lil health's Anxiety Risk and Depression Risk show them: each " +
      "one's score out of its maximum, the risk Health gave it, and every question's answer, " +
      "with the period's count. They're screening questionnaires people take in the Health " +
      "app, not diagnoses.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthAssessmentsResult,
    failure: HealthToolError,
  }),
  "Health Assessments",
);

// -------------------------------------------------------------------------------------------------
// electrocardiograms and electrocardiogram_voltages
// -------------------------------------------------------------------------------------------------

/** The most ECGs `electrocardiograms` lists. */
export const electrocardiogramsLimit = 100;
/** The seconds of a recording `electrocardiogram_voltages` gives a page by default, and at most. */
export const voltagesDefaultSeconds = 10;
export const voltagesMaxSeconds = 30;
/**
 * The most values a page of voltages has: Apple Watch's whole recording, 30 seconds at 512 Hz,
 * about 150 KB at its longest. A page that would have more, from a device that measures faster,
 * is downsampled, so it stays under the 256 KB ceiling.
 */
export const voltagesValueLimit = 15_360;

const electrocardiogramIdParameter = Schema.String.annotate({
  description: "An ECG's ID, from electrocardiograms.",
});

export const HealthElectrocardiogramSymptom = Schema.Struct({
  type: healthType.annotate({
    description:
      "The symptom's category type, e.g. HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat.",
  }),
  name: Schema.String.annotate({
    description: "The name Health gives it, e.g. Rapid, Pounding, or Fluttering Heartbeat.",
  }),
}).annotate({ identifier: "HealthElectrocardiogramSymptom" });

export const HealthElectrocardiogramItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the recording." }),
  start: LocalTime,
  end: LocalTime,
  ...recordedTimeFields,
  duration: Schema.Finite.annotate({
    description: "Seconds, from start to end: 30 for Apple Watch's ECG app.",
  }),
  classification: Schema.String.annotate({
    description:
      "What the ECG app classified the rhythm as, as Health names it: Sinus Rhythm (no signs " +
      "of atrial fibrillation), Atrial Fibrillation, Low Heart Rate (under 50 BPM, too slow to " +
      "check), High Heart Rate (too fast to check: over 120 BPM, or 150 BPM from algorithm " +
      "version 2), Poor Recording, Inconclusive, Unrecognized, or Not Classified. A screening " +
      "result from the person's watch, not a diagnosis.",
  }),
  averageHeartRate: Schema.NullOr(Schema.Finite).annotate({
    description: "The average heart rate during the recording, in beats per minute, or null.",
  }),
  samplingFrequency: Schema.NullOr(Schema.Finite).annotate({
    description:
      "Voltage measurements per second (Hz), as recorded: 512 for Apple Watch. Null if the " +
      "recording doesn't say.",
  }),
  voltageCount: Schema.Int.annotate({
    description:
      "How many voltage measurements it has: 15,360 for 30 seconds at 512 Hz. " +
      "electrocardiogram_voltages reads them; 0 for a recording without any.",
  }),
  symptoms: Schema.String.annotate({
    description:
      "Whether symptoms were logged with it, as lil health shows it: Symptoms Logged, No " +
      "Symptoms, or Not Logged (they weren't asked about). loggedSymptoms says which.",
  }),
  loggedSymptoms: Schema.NullOr(Schema.Array(HealthElectrocardiogramSymptom)).annotate({
    description:
      "The symptoms logged with it (HKQuery.predicateForObjectsAssociated), in the order they " +
      "were logged: empty when none were. Null when lil health doesn't know which: for a " +
      "recording an older lil health on the iPhone uploaded, until an updated one reads its " +
      "links. Its symptoms are then symptom samples logged around its time, which samples " +
      "lists by type.",
  }),
  algorithmVersion: Schema.optionalKey(
    Schema.Finite.annotate({
      description:
        "The version of the ECG app's algorithm that classified it " +
        "(HKMetadataKeyAppleECGAlgorithmVersion): 1, or 2, which classifies heart rates up to " +
        "150 BPM. Left out when it doesn't say.",
    }),
  ),
  source: Schema.String.annotate({
    description: "The app or device that recorded it, e.g. ECG on Apple Watch.",
  }),
}).annotate({ identifier: "HealthElectrocardiogramItem" });

export const HealthElectrocardiogramsResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({ description: "ECGs that start in the period, all of them." }),
  recordings: Schema.Array(HealthElectrocardiogramItem).annotate({
    description: `The recordings, newest first, at most ${electrocardiogramsLimit}.`,
  }),
});

export const Electrocardiograms = readOnly(
  Tool.make("electrocardiograms", {
    description:
      "ECG recordings (from the ECG app on Apple Watch, or another app) that started in a " +
      "period, newest first, as lil health's ECG page lists them: each one's classification " +
      "(e.g. Sinus Rhythm or Atrial Fibrillation), average heart rate, sampling frequency, " +
      "how many voltage measurements it has and the symptoms logged with it, with the " +
      "period's count. Its voltages come from electrocardiogram_voltages, a page at a time: " +
      "ask for them only when the classification and heart rate aren't enough.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthElectrocardiogramsResult,
    failure: HealthToolError,
  }),
  "Health ECGs",
);

export const HealthElectrocardiogramVoltagesResult = Schema.Struct({
  timeZone: usedTimeZone,
  id: Schema.String.annotate({ description: "The recording's ID." }),
  start: LocalTime.annotate({ description: "When the recording starts." }),
  samplingFrequency: Schema.Finite.annotate({
    description:
      "The recording's measurements per second (Hz): as recorded, or if it doesn't say, its " +
      "measurements over its duration (512 if that can't tell either).",
  }),
  voltageCount: Schema.Int.annotate({
    description: "How many measurements the recording has, all of them.",
  }),
  offset: Schema.Finite.annotate({
    description: "Seconds from the recording's start to this page's first value.",
  }),
  rate: Schema.Finite.annotate({
    description:
      "This page's values per second: samplingFrequency, or less when the page is downsampled.",
  }),
  measurementsPerValue: Schema.Int.annotate({
    description:
      "How many measurements each value stands for: 1, or when the page is downsampled to " +
      `stay under ${voltagesValueLimit.toLocaleString("en-US")} values, the average of that ` +
      "many in a row (the last value may average fewer).",
  }),
  values: Schema.Array(Schema.NullOr(Schema.Finite)).annotate({
    description:
      "The voltages, in microvolts (µV), in order, `rate` a second from `offset`: Apple " +
      "Watch's lead I, as on ECG paper (1 mV is 1,000 µV). Stored as 32-bit floats, so " +
      "rounded to 2 decimal places. Null where the recording has no value.",
  }),
  nextCursor: Schema.NullOr(Schema.String).annotate({
    description: "Pass it as `cursor` for the next page; null on the last page.",
  }),
});

export const ElectrocardiogramVoltages = readOnly(
  Tool.make("electrocardiogram_voltages", {
    description:
      "One ECG recording's voltages, in microvolts, a page of seconds at a time, in order: " +
      `${voltagesDefaultSeconds} seconds a page by default, at its own rate (Apple Watch's is ` +
      "512 a second, so 5,120 values). Each page says its rate, and is downsampled (each value " +
      `the average of a few measurements) only if it would have more than ` +
      `${voltagesValueLimit.toLocaleString("en-US")} values. By its ID, from ` +
      "electrocardiograms, whose classification and heart rate usually answer what's asked: " +
      "call this only to look at the trace itself.",
    parameters: Schema.Struct({
      id: electrocardiogramIdParameter,
      timeZone,
      cursor: Schema.optionalKey(
        Schema.String.annotate({ description: "The previous page's nextCursor." }),
      ),
      seconds: Schema.optionalKey(
        Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: voltagesMaxSeconds })).annotate({
          description:
            `Seconds of the recording per page, at most ${voltagesMaxSeconds} (a whole Apple ` +
            `Watch recording). Defaults to ${voltagesDefaultSeconds}.`,
        }),
      ),
    }),
    success: HealthElectrocardiogramVoltagesResult,
    failure: HealthToolError,
  }),
  "Health ECG Voltages",
);

// -------------------------------------------------------------------------------------------------
// heartbeat_series and heartbeat_series_beats
// -------------------------------------------------------------------------------------------------

/** The most heartbeat series `heartbeat_series` lists. */
export const heartbeatSeriesLimit = 100;
/**
 * The most beats `heartbeat_series_beats` gives a page, and how many it gives by default: an Apple
 * Watch series' hundred or so in one page, and about 120 KB at most, with every value at its
 * longest.
 */
export const heartbeatBeatsLimit = 2000;
export const heartbeatBeatsDefaultLimit = 1000;

const heartbeatSeriesIdParameter = Schema.String.annotate({
  description: "A heartbeat series' ID, from heartbeat_series.",
});

/**
 * How the tools work out a series' intervals and HRV (851-4162), as lil health's Beat-to-Beat
 * Measurements page does (`HeartbeatAnalysis` on the Mac).
 */
const heartbeatIntervals =
  "An interval is the time from one beat to the next. A beat preceded by a gap (beats " +
  "HealthKit couldn't measure came before it) starts afresh: there's no interval from the beat " +
  "before it, and no difference of intervals spans the gap. An interval of 0 (two beats at the " +
  "same time) is skipped as a duplicate beat. Beats aren't filtered otherwise: no ectopic or " +
  "artifact correction.";

export const HealthHeartbeatSeriesItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the series." }),
  start: LocalTime,
  end: LocalTime,
  ...recordedTimeFields,
  beatCount: Schema.Int.annotate({ description: "How many beats it has, all of them." }),
  duration: Schema.Finite.annotate({
    description: "Seconds from its first beat to its last, to 4 decimal places (0.1 ms).",
  }),
  gapCount: Schema.Int.annotate({
    description: "How many of its beats are preceded by a gap (precededByGap).",
  }),
  intervalCount: Schema.Int.annotate({
    description: "How many intervals between beats the averages below are worked out from.",
  }),
  averageHeartRate: Schema.NullOr(Schema.Finite).annotate({
    description:
      "60 over the mean interval in seconds, in beats per minute, to 2 decimal places; null " +
      "without an interval.",
  }),
  sdnn: Schema.NullOr(Schema.Finite).annotate({
    description:
      "SDNN, in ms, to 2 decimal places: the sample standard deviation of the intervals " +
      "(dividing by their count less 1). Apple Health's Heart Rate Variability is an SDNN, " +
      "which Apple works out itself, so it can differ a little. Null with fewer than 2 intervals.",
  }),
  rmssd: Schema.NullOr(Schema.Finite).annotate({
    description:
      "RMSSD, in ms, to 2 decimal places: the root mean square of the differences between " +
      "each interval and the one before it, within each run of beats without a gap. Null " +
      "without two intervals in a row.",
  }),
  source: Schema.String.annotate({
    description: "The app or device that measured it, e.g. Apple Watch.",
  }),
}).annotate({ identifier: "HealthHeartbeatSeriesItem" });

export const HealthHeartbeatSeriesResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({
    description: "Heartbeat series that start in the period, all of them.",
  }),
  series: Schema.Array(HealthHeartbeatSeriesItem).annotate({
    description: `The series, newest first, at most ${heartbeatSeriesLimit}.`,
  }),
});

export const HeartbeatSeries = readOnly(
  Tool.make("heartbeat_series", {
    description:
      "Heartbeat series (Apple Watch's beat-to-beat measurements, behind Health's Heart Rate " +
      "Variability readings, about a minute and a hundred beats each, or another app's) that " +
      "started in a period, newest first, as lil health's Beat-to-Beat Measurements page lists " +
      "them: each one's beat count, duration, gaps, and its average heart rate, SDNN and RMSSD " +
      `worked out from its intervals, with the period's count. ${heartbeatIntervals} Each ` +
      "series' beats come from heartbeat_series_beats, a page at a time: ask for them only " +
      "when these summaries aren't enough. For HRV over weeks or months, metric of " +
      "HKQuantityTypeIdentifierHeartRateVariabilitySDNN is shorter.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthHeartbeatSeriesResult,
    failure: HealthToolError,
  }),
  "Health Heartbeat Series",
);

export const HealthHeartbeat = Schema.Struct({
  time: Schema.Finite.annotate({
    description: "Seconds from the series' start to the beat, to 4 decimal places (0.1 ms).",
  }),
  interval: Schema.NullOr(Schema.Finite).annotate({
    description:
      "Milliseconds since the beat before, to 1 decimal place; null for the series' first " +
      "beat and a beat preceded by a gap, and 0 for a duplicate beat (at the same time as the " +
      "one before), which heartbeat_series' averages skip.",
  }),
  precededByGap: Schema.Boolean.annotate({
    description:
      "Whether beats HealthKit couldn't measure came before it, so the time since the beat " +
      "before isn't an interval between two beats.",
  }),
}).annotate({ identifier: "HealthHeartbeat" });

export const HealthHeartbeatSeriesBeatsResult = Schema.Struct({
  timeZone: usedTimeZone,
  id: Schema.String.annotate({ description: "The series' ID." }),
  start: LocalTime.annotate({ description: "When the series starts: its beats' time 0." }),
  beatCount: Schema.Int.annotate({ description: "How many beats the series has, all of them." }),
  beats: Schema.Array(HealthHeartbeat).annotate({ description: "This page's beats, in order." }),
  nextCursor: Schema.NullOr(Schema.String).annotate({
    description: "Pass it as `cursor` for the next page; null on the last page.",
  }),
});

export const HeartbeatSeriesBeats = readOnly(
  Tool.make("heartbeat_series_beats", {
    description:
      "One heartbeat series' beats, in order, a page at a time: each beat's time since the " +
      "series' start, the interval since the beat before in ms, and whether a gap preceded it, " +
      `to work out HRV or look at the rhythm another way. ${heartbeatIntervals} ` +
      "heartbeat_series works out the average heart rate, SDNN and RMSSD by these rules. By " +
      "its ID, from heartbeat_series, " +
      "whose average heart rate, SDNN and RMSSD usually answer what's asked: call this only " +
      `when they don't. ${heartbeatBeatsDefaultLimit.toLocaleString("en-US")} beats a page ` +
      "by default, which is a whole Apple Watch series.",
    parameters: Schema.Struct({
      id: heartbeatSeriesIdParameter,
      timeZone,
      cursor: Schema.optionalKey(
        Schema.String.annotate({ description: "The previous page's nextCursor." }),
      ),
      limit: Schema.optionalKey(
        Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: heartbeatBeatsLimit })).annotate({
          description:
            `Beats per page, at most ${heartbeatBeatsLimit.toLocaleString("en-US")}. ` +
            `Defaults to ${heartbeatBeatsDefaultLimit.toLocaleString("en-US")}.`,
        }),
      ),
    }),
    success: HealthHeartbeatSeriesBeatsResult,
    failure: HealthToolError,
  }),
  "Health Heartbeat Series Beats",
);

// -------------------------------------------------------------------------------------------------
// audiograms
// -------------------------------------------------------------------------------------------------

/** The most audiograms `audiograms` lists. */
export const audiogramsLimit = 30;

export const HealthAudiogramTest = Schema.Struct({
  sensitivity: Schema.Finite.annotate({
    description:
      "The quietest sound heard at this frequency, in dBHL (decibels hearing level): 0 is " +
      "typical hearing, and higher means a louder sound was needed. Can be below 0.",
  }),
  conduction: Schema.String.annotate({
    description:
      "How the sound was played: Air (through headphones or the air, as hearing tests do), or " +
      "Unknown for a kind a later iOS adds.",
  }),
  masked: Schema.Boolean.annotate({
    description: "Whether the other ear was masked with noise during the test.",
  }),
  clamped: Schema.Boolean.annotate({
    description:
      "Whether the result is a bound rather than a threshold: the test has a clamping range " +
      "(clampingLower, clampingUpper), and the threshold lies within it. A lower bound alone " +
      "means no response up to the device's loudest, so the threshold is at or past " +
      "sensitivity; lil health's chart marks it with a down arrow.",
  }),
  clampingLower: Schema.optionalKey(
    Schema.Finite.annotate({
      description: "The clamping range's lower bound, in dBHL. Left out without one.",
    }),
  ),
  clampingUpper: Schema.optionalKey(
    Schema.Finite.annotate({
      description: "The clamping range's upper bound, in dBHL. Left out without one.",
    }),
  ),
}).annotate({ identifier: "HealthAudiogramTest" });

const earTests = (ear: string) =>
  Schema.Array(HealthAudiogramTest).annotate({
    description:
      `The ${ear} ear's tests at this frequency, the one lil health charts and averages first ` +
      "(air conduction, unmasked before masked), then any others as recorded. Empty if that " +
      "ear wasn't tested here.",
  });

export const HealthAudiogramPoint = Schema.Struct({
  frequency: Schema.Finite.annotate({ description: "The tone's frequency, in Hz, e.g. 1000." }),
  left: earTests("left"),
  right: earTests("right"),
}).annotate({ identifier: "HealthAudiogramPoint" });

export const HealthAudiogramEar = Schema.Struct({
  hearingLevel: Schema.NullOr(Schema.Finite).annotate({
    description:
      "The ear's hearing level, in whole dBHL, as lil health's Audiogram page shows it: the " +
      "average of its charted sensitivities at 500, 1000, 2000 and 4000 Hz (the speech range), " +
      "or of every frequency tested if none of those was. Null if the ear wasn't tested (Not " +
      "Tested on the page).",
  }),
  hearingLoss: Schema.NullOr(Schema.String).annotate({
    description:
      "What the hearing level means, as the page says it: Little to No Hearing Loss (up to 25 " +
      "dBHL), Mild Hearing Loss (up to 40), Moderate Hearing Loss (up to 60), Severe Hearing " +
      "Loss (up to 80) or Profound Hearing Loss. Null if the ear wasn't tested.",
  }),
}).annotate({ identifier: "HealthAudiogramEar" });

export const HealthAudiogramItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the audiogram." }),
  start: LocalTime,
  end: LocalTime,
  ...recordedTimeFields,
  leftEar: HealthAudiogramEar,
  rightEar: HealthAudiogramEar,
  points: Schema.Array(HealthAudiogramPoint).annotate({
    description:
      "Each frequency tested, as recorded (lowest first), with each ear's results. Empty if " +
      "none can be read.",
  }),
  source: Schema.String.annotate({
    description: "The app or device that recorded it, e.g. AirPods Pro's Hearing Test.",
  }),
}).annotate({ identifier: "HealthAudiogramItem" });

export const HealthAudiogramsResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({ description: "Audiograms that start in the period, all of them." }),
  audiograms: Schema.Array(HealthAudiogramItem).annotate({
    description: `The audiograms, newest first, at most ${audiogramsLimit}.`,
  }),
});

export const Audiograms = readOnly(
  Tool.make("audiograms", {
    description:
      "Audiograms (hearing test results, from the Hearing Test on AirPods Pro or another app) " +
      "that started in a period, newest first, as lil health's Audiogram page shows them: each " +
      "ear's hearing level (its average in dBHL) and what it means (e.g. Mild Hearing Loss), " +
      "and each frequency tested with each ear's sensitivity in dBHL, how it was tested " +
      "(conduction, masking) and whether the result is a bound (clamped), with the period's " +
      "count. A screening result, not a diagnosis.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthAudiogramsResult,
    failure: HealthToolError,
  }),
  "Health Audiograms",
);

// -------------------------------------------------------------------------------------------------
// health_documents and health_document
// -------------------------------------------------------------------------------------------------

/** The most Health Documents `health_documents` lists. */
export const healthDocumentsLimit = 100;
/**
 * The most characters (UTF-16 code units) a page of a document's XML has, and its default: 40,000
 * is at most 240 KB as JSON, a character at its longest escaped (`\u0001`), under the 256 KB
 * ceiling; an XML document's are mostly 1 byte.
 */
export const healthDocumentPageLimit = 40_000;

/** A name HealthKit read from a document, as the Mac's Health Documents page shows it. */
const documentName = (row: string, what: string) =>
  Schema.NullOr(Schema.String).annotate({
    description:
      `${what}, as HealthKit read it from the document and lil health's Health Documents page ` +
      `shows it (its ${row} row). Null if HealthKit found none.`,
  });

export const HealthDocumentItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the document." }),
  title: Schema.String.annotate({
    description:
      "The document's title, as HealthKit read it from the document (e.g. Visit Summary), or " +
      "Health Document if it has none, as lil health's Health Documents page shows it.",
  }),
  patient: documentName("Patient", "Who the document is about"),
  author: documentName("Author", "Who wrote it: a clinician, or the system that made it"),
  custodian: documentName("Custodian", "The organization that keeps it, e.g. a clinic"),
  start: LocalTime.annotate({
    description:
      "The document's date (its Date on lil health's page), as the app that saved it to Health " +
      "dated it: usually the visit or period it covers.",
  }),
  end: LocalTime,
  ...recordedTimeFields,
  source: Schema.String.annotate({
    description: "The app that saved it to Health, e.g. a clinic's or a health records app.",
  }),
}).annotate({ identifier: "HealthDocumentItem" });

export const HealthDocumentsResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({
    description: "Health Documents that start in the period, all of them.",
  }),
  documents: Schema.Array(HealthDocumentItem).annotate({
    description: `The documents, newest first, at most ${healthDocumentsLimit}.`,
  }),
});

export const HealthDocuments = readOnly(
  Tool.make("health_documents", {
    description:
      "Health Documents (clinical documents in HL7's CDA format, such as a visit summary a " +
      "provider sent, that the person shared with Health) whose date is in a period, newest " +
      "first, as lil health's Health Documents page lists them: each one's title, patient, " +
      "author, custodian (the organization that keeps it), date and source, with the " +
      "period's count. What a document says (diagnoses, medications, test results, the " +
      "patient's details) comes from health_document, a page at a time: ask for it only when " +
      "its title and names aren't enough.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthDocumentsResult,
    failure: HealthToolError,
  }),
  "Health Documents",
);

export const HealthDocumentResult = Schema.Struct({
  timeZone: usedTimeZone,
  id: Schema.String.annotate({ description: "The document's ID." }),
  title: Schema.String.annotate({
    description: "Its title, as health_documents gives it.",
  }),
  start: LocalTime.annotate({ description: "The document's date." }),
  length: Schema.Int.annotate({
    description:
      "How long the document's XML is, in characters (UTF-16 code units, as JavaScript counts " +
      "a string's length: a character outside the Basic Multilingual Plane, such as an emoji, " +
      "is 2).",
  }),
  offset: Schema.Int.annotate({
    description: "Where this page starts in the XML, in the same characters.",
  }),
  xml: Schema.String.annotate({
    description:
      "This page of the document's CDA XML, exactly as the provider wrote it (namespace " +
      "urn:hl7-org:v3), decoded as text: the header (recordTarget is the patient, with their " +
      "address and birth date; author, custodian, the visit), then the structured body, each " +
      "<section> a <title>, a human-readable <text> (paragraphs, lists, tables) and coded " +
      "<entry>s that repeat it with codes (e.g. SNOMED CT, LOINC, RxNorm), values, units and " +
      "reference ranges. A page can end inside an element: the next page goes on from there.",
  }),
  nextCursor: Schema.NullOr(Schema.String).annotate({
    description: "Pass it as `cursor` for the next page; null on the last page.",
  }),
});

export const HealthDocumentContent = readOnly(
  Tool.make("health_document", {
    description:
      "One Health Document's content: its CDA XML, as the provider wrote it, " +
      `${healthDocumentPageLimit.toLocaleString("en-US")} characters a page, in order. By its ` +
      "ID, from health_documents, whose titles and names usually answer what's asked: call " +
      "this only to read what a document says, such as its diagnoses, medications or test " +
      "results. The XML is decoded as text by its byte order mark or XML declaration (UTF-8, " +
      "UTF-16, ISO-8859-1 or windows-1252; UTF-8 otherwise).",
    parameters: Schema.Struct({
      id: Schema.String.annotate({ description: "A document's ID, from health_documents." }),
      timeZone,
      cursor: Schema.optionalKey(
        Schema.String.annotate({ description: "The previous page's nextCursor." }),
      ),
      limit: Schema.optionalKey(
        Schema.Int.check(
          Schema.isBetween({ minimum: 1, maximum: healthDocumentPageLimit }),
        ).annotate({
          description:
            `Characters per page, at most ${healthDocumentPageLimit.toLocaleString("en-US")}, ` +
            "the default. A page never splits a character outside the Basic Multilingual Plane, " +
            "so it can have one more.",
        }),
      ),
    }),
    success: HealthDocumentResult,
    failure: HealthToolError,
  }),
  "Health Document",
);

// -------------------------------------------------------------------------------------------------
// medications
// -------------------------------------------------------------------------------------------------

const adherence = Schema.Struct({
  scheduled: Schema.Int.annotate({ description: "Scheduled doses that were due." }),
  taken: Schema.Int.annotate({ description: "Of those, how many were logged as taken." }),
  asNeeded: Schema.Int.annotate({ description: "Doses taken as needed." }),
});

export const HealthMedicationCoding = Schema.Struct({
  system: Schema.String.annotate({
    description:
      "The coding system, as HealthKit names it, e.g. http://www.nlm.nih.gov/research/umls/rxnorm.",
  }),
  version: Schema.NullOr(Schema.String).annotate({
    description: "The system's version, or null.",
  }),
  code: Schema.String.annotate({ description: "The code in that system, e.g. an RxNorm RxCUI." }),
}).annotate({ identifier: "HealthMedicationCoding" });

export const HealthMedicationItem = Schema.Struct({
  id: Schema.String,
  name: Schema.String.annotate({ description: "The name the person gave it, else Health's." }),
  healthName: Schema.String.annotate({ description: "The name Health shows for it." }),
  form: Schema.String.annotate({
    description: "Its general form, as HealthKit names it, e.g. tablet or capsule.",
  }),
  archived: Schema.Boolean,
  scheduled: Schema.Boolean.annotate({
    description: "Whether it's taken on a schedule, rather than as needed.",
  }),
  last7Days: adherence.annotate({ description: "Adherence over today and the 6 days before." }),
  last30Days: adherence.annotate({ description: "Adherence over today and the 29 days before." }),
  lastTaken: Schema.NullOr(LocalTime).annotate({
    description: "When a dose was last logged as taken, or null.",
  }),
  codings: Schema.Array(HealthMedicationCoding).annotate({
    description:
      "Codes for it in clinical coding systems (HKClinicalCoding), which name the drug " +
      "exactly, e.g. RxNorm's, as Health has them. Empty if Health has none.",
  }),
}).annotate({ identifier: "HealthMedicationItem" });

export const HealthMedicationsResult = Schema.Struct({
  timeZone: usedTimeZone,
  medications: Schema.Array(HealthMedicationItem).annotate({
    description: "Current medications, then archived ones, by name.",
  }),
});

export const Medications = readOnly(
  Tool.make("medications", {
    description:
      "The medications the person shares with lil health, with their form and schedule, how " +
      "many scheduled doses they took over the last 7 and 30 days, when they last took each, " +
      "and their clinical codes (e.g. RxNorm). medication_doses lists each dose logged.",
    parameters: Schema.Struct({ timeZone }),
    success: HealthMedicationsResult,
    failure: HealthToolError,
  }),
  "Health Medications",
);

// -------------------------------------------------------------------------------------------------
// medication_doses
// -------------------------------------------------------------------------------------------------

/** The most doses one call returns, and how many it returns by default. */
export const medicationDosesLimit = 250;
export const medicationDosesDefaultLimit = 100;

export const HealthMedicationDoseItem = Schema.Struct({
  medicationId: Schema.String.annotate({
    description: "The medication's ID, as medications gives it.",
  }),
  medication: Schema.String.annotate({
    description: "The medication's name: the one the person gave it, else Health's.",
  }),
  status: Schema.String.annotate({
    description:
      "What happened to it, as lil health's Medications page says it: Taken, Skipped, Snoozed, " +
      "Not Logged (a scheduled dose nobody logged, or a status the person undid), Reminder Not " +
      "Sent, or Unknown for one a later iOS adds.",
  }),
  schedule: Schema.String.annotate({
    description:
      "Scheduled (due at scheduledTime) or As Needed, or Unknown for one a later iOS adds.",
  }),
  time: LocalTime.annotate({
    description:
      "When it was logged (taken, skipped or snoozed), or for a scheduled dose nobody logged, " +
      "when Health marked it.",
  }),
  scheduledTime: Schema.NullOr(LocalTime).annotate({
    description:
      "When it was due, for a scheduled dose; null for one taken as needed. A dose belongs to " +
      "the day it was due, however long before or after it was logged.",
  }),
  ...recordedMomentFields,
  recordedScheduledTime: recordedClock("When it was due"),
  amount: Schema.NullOr(Schema.Finite).annotate({
    description: "The dose logged, in `unit`, or null: usually only a taken dose has one.",
  }),
  scheduledAmount: Schema.NullOr(Schema.Finite).annotate({
    description: "The dose scheduled, in `unit`, or null for one taken as needed.",
  }),
  unit: Schema.String.annotate({
    description:
      "The amounts' unit, as HealthKit writes it, e.g. mg or mL; count is the medication's own " +
      "units, its form's (tablets, capsules, puffs…).",
  }),
  source: Schema.String.annotate({
    description: "The app or device it was logged in, e.g. Health.",
  }),
}).annotate({ identifier: "HealthMedicationDoseItem" });

export const HealthMedicationDosesResult = Schema.Struct({
  ...periodFields,
  count: Schema.Int.annotate({
    description: "Doses in the period, of every page: the medication's, if one was asked for.",
  }),
  doses: Schema.Array(HealthMedicationDoseItem).annotate({
    description:
      "This page's doses, newest first by when they were due (or logged, for one taken as " +
      "needed), as lil health's dose log lists them.",
  }),
  nextCursor: Schema.NullOr(Schema.String).annotate({
    description: "Pass it as `cursor` for the next, older page; null on the last page.",
  }),
});

export const MedicationDoses = readOnly(
  Tool.make("medication_doses", {
    description:
      "The dose log of the medications the person shares: each dose in a period, newest " +
      "first, a page at a time, in the words of lil health's Medications page: which " +
      "medication, whether it was taken, skipped, snoozed or not logged, scheduled or as " +
      "needed, when it was logged and when it was due, and the amount, with the period's " +
      "count. A dose counts on the day it was due (or was logged, if taken as needed). For " +
      "adherence over the last 7 and 30 days, use medications.",
    parameters: Schema.Struct({
      range,
      date,
      timeZone,
      medication: Schema.optionalKey(
        Schema.String.annotate({
          description: "Only this medication's doses, by the ID medications gives it.",
        }),
      ),
      cursor: Schema.optionalKey(
        Schema.String.annotate({ description: "The previous page's nextCursor." }),
      ),
      limit: Schema.optionalKey(
        Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: medicationDosesLimit })).annotate({
          description:
            `Doses per page, at most ${medicationDosesLimit}. Defaults to ` +
            `${medicationDosesDefaultLimit}.`,
        }),
      ),
    }),
    success: HealthMedicationDosesResult,
    failure: HealthToolError,
  }),
  "Health Medication Doses",
);

// -------------------------------------------------------------------------------------------------
// health_details
// -------------------------------------------------------------------------------------------------

const lens = Schema.NullOr(
  Schema.Struct({
    sphere: Schema.NullOr(Schema.Finite).annotate({ description: "Diopters." }),
    cylinder: Schema.NullOr(Schema.Finite).annotate({ description: "Diopters." }),
    axis: Schema.NullOr(Schema.Finite).annotate({ description: "Degrees." }),
    addPower: Schema.NullOr(Schema.Finite).annotate({ description: "Diopters." }),
  }),
);

export const HealthVisionPrescriptionItem = Schema.Struct({
  id: Schema.String,
  kind: Schema.String.annotate({ description: "glasses or contacts." }),
  issued: LocalDate,
  expires: Schema.NullOr(LocalDate),
  brand: Schema.NullOr(Schema.String).annotate({ description: "A contacts lens brand." }),
  rightEye: lens.annotate({ description: "The right eye (OD), or null if not covered." }),
  leftEye: lens.annotate({ description: "The left eye (OS), or null if not covered." }),
}).annotate({ identifier: "HealthVisionPrescriptionItem" });

export const HealthDetailsResult = Schema.Struct({
  timeZone: usedTimeZone,
  dateOfBirth: Schema.NullOr(LocalDate),
  age: Schema.NullOr(Schema.Int).annotate({ description: "Years, as of today." }),
  sex: Schema.NullOr(Schema.String).annotate({
    description: "As Health records it: female, male or other. Null if not set.",
  }),
  bloodType: Schema.NullOr(Schema.String).annotate({ description: "E.g. A+ or O-." }),
  fitzpatrickSkinType: Schema.NullOr(Schema.String).annotate({ description: "I to VI." }),
  wheelchairUse: Schema.NullOr(Schema.Boolean),
  visionPrescriptions: Schema.Array(HealthVisionPrescriptionItem).annotate({
    description: "Glasses and contacts prescriptions the person shares, newest first.",
  }),
});

export const HealthDetails = readOnly(
  Tool.make("health_details", {
    description:
      "The person's health details as Health keeps them: date of birth and age, sex, blood " +
      "type, skin type and wheelchair use (null when not set), and their vision prescriptions.",
    parameters: Schema.Struct({ timeZone }),
    success: HealthDetailsResult,
    failure: HealthToolError,
  }),
  "Health Details",
);

// -------------------------------------------------------------------------------------------------
// search
// -------------------------------------------------------------------------------------------------

export const HealthSearchType = Schema.Struct({
  type: healthType,
  name: Schema.String,
  category: Schema.NullOr(Schema.String),
  hasData: Schema.Boolean.annotate({ description: "Whether the person has any of it." }),
}).annotate({ identifier: "HealthSearchType" });

export const HealthSearchMedication = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
}).annotate({ identifier: "HealthSearchMedication" });

export const HealthSearchResult = Schema.Struct({
  types: Schema.Array(HealthSearchType).annotate({
    description: "Data types whose name or category matches, those with data first.",
  }),
  medications: Schema.Array(HealthSearchMedication).annotate({
    description: "Medications whose name matches.",
  }),
});

export const Search = readOnly(
  Tool.make("search", {
    description:
      "Finds data types (and medications) by name, e.g. 'blood pressure', 'vo2' or 'sleep', " +
      "to get the identifiers metric and samples take. Matches every type lil health knows, " +
      "saying which have data.",
    parameters: Schema.Struct({
      query: Schema.String.check(Schema.isBetweenLength(1, 100)).annotate({
        description: "Words to look for in names, case-insensitive.",
      }),
    }),
    success: HealthSearchResult,
    failure: HealthToolError,
  }),
  "Search Health Data",
);

// -------------------------------------------------------------------------------------------------
// sync_status
// -------------------------------------------------------------------------------------------------

export const HealthSyncIPhone = Schema.Struct({
  device: Schema.String.annotate({ description: "lil's ID for the iPhone." }),
  pairedWithWatch: Schema.Boolean,
  lastReported: LocalTime.annotate({
    description: "When its last upload of statistics was applied.",
  }),
  statisticsSource: Schema.Boolean.annotate({
    description: "Whether totals come from this iPhone's statistics.",
  }),
}).annotate({ identifier: "HealthSyncIPhone" });

export const HealthSyncStatusResult = Schema.Struct({
  timeZone: usedTimeZone,
  latestSample: Schema.NullOr(LocalTime).annotate({
    description: "When the most recent sample that has started starts, or null without data.",
  }),
  iPhones: Schema.Array(HealthSyncIPhone).annotate({
    description: "The iPhones uploading Health data, most recently reported first.",
  }),
});

export const SyncStatus = readOnly(
  Tool.make("sync_status", {
    description:
      "How fresh the data is: the newest sample, and each iPhone that uploads Health data, " +
      "when it last reported and which one totals come from. Check it when data looks missing " +
      "or out of date.",
    parameters: Schema.Struct({ timeZone }),
    success: HealthSyncStatusResult,
    failure: HealthToolError,
  }),
  "Health Sync Status",
);

// -------------------------------------------------------------------------------------------------
// The toolkit
// -------------------------------------------------------------------------------------------------

export const HealthToolkit = Toolkit.make(
  Summary,
  ListTypes,
  Metric,
  Samples,
  Workouts,
  Workout,
  WorkoutRoutes,
  WorkoutRoute,
  WorkoutRoutePoints,
  Sleep,
  ActivityRings,
  StateOfMind,
  Assessments,
  Electrocardiograms,
  ElectrocardiogramVoltages,
  HeartbeatSeries,
  HeartbeatSeriesBeats,
  Audiograms,
  HealthDocuments,
  HealthDocumentContent,
  Medications,
  MedicationDoses,
  HealthDetails,
  Search,
  SyncStatus,
);

/**
 * The name each tool's output schema has in `openapi.json`, so the Swift client gets a type for
 * it (`Components.Schemas.HealthSummaryResult`). Outputs aren't named in the toolkit itself, so
 * MCP's output schemas stay a plain object at the root.
 */
export const healthToolResultNames: Record<keyof typeof HealthToolkit.tools, string> = {
  summary: "HealthSummaryResult",
  list_types: "HealthTypesResult",
  metric: "HealthMetricResult",
  samples: "HealthSamplesResult",
  workouts: "HealthWorkoutsResult",
  workout: "HealthWorkoutResult",
  workout_routes: "HealthWorkoutRoutesResult",
  workout_route: "HealthWorkoutRouteResult",
  workout_route_points: "HealthWorkoutRoutePointsResult",
  sleep: "HealthSleepResult",
  activity_rings: "HealthActivityRingsResult",
  state_of_mind: "HealthStateOfMindResult",
  assessments: "HealthAssessmentsResult",
  electrocardiograms: "HealthElectrocardiogramsResult",
  electrocardiogram_voltages: "HealthElectrocardiogramVoltagesResult",
  heartbeat_series: "HealthHeartbeatSeriesResult",
  heartbeat_series_beats: "HealthHeartbeatSeriesBeatsResult",
  audiograms: "HealthAudiogramsResult",
  health_documents: "HealthDocumentsResult",
  health_document: "HealthDocumentResult",
  medications: "HealthMedicationsResult",
  medication_doses: "HealthMedicationDosesResult",
  health_details: "HealthDetailsResult",
  search: "HealthSearchResult",
  sync_status: "HealthSyncStatusResult",
};

/** Handlers for every tool, as an implementation provides them (`HealthToolkit.toLayer`). */
export type HealthToolHandlers = Toolkit.HandlersFrom<typeof HealthToolkit.tools>;

/**
 * `handlers` completed with a handler that dies for every tool they leave out, for an
 * implementation that has some of the tools so far, or none (listing tools never calls them).
 */
export const withUnimplementedTools = (handlers: Partial<HealthToolHandlers>): HealthToolHandlers =>
  Object.fromEntries(
    Object.keys(HealthToolkit.tools).map((name) => [
      name,
      handlers[name as keyof HealthToolHandlers] ??
        (() => Effect.die(`The ${name} tool isn't implemented yet`)),
    ]),
  ) as unknown as HealthToolHandlers;
