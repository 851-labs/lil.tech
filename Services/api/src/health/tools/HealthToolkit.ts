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

const timeZone = Schema.optionalKey(
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

/** Whether a `YYYY-MM-DD` string is a day that exists (not 2026-02-31). */
export const isDay = (day: string) => {
  const parsed = new Date(`${day}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(day);
};

const date = Schema.optionalKey(
  Schema.String.check(
    Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/),
    Schema.makeFilter((day: string) => isDay(day) || "must be a day that exists"),
  ).annotate({
    description: "The last day of the period, as YYYY-MM-DD in `timeZone`. Defaults to today.",
  }),
);

const healthType = Schema.String.annotate({
  description:
    "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or " +
    "HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them.",
});

const LocalTime = Schema.String.annotate({
  description:
    "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. " +
    "2026-10-20T08:15:00+01:00.",
});

const LocalDate = Schema.String.annotate({
  description: "A day in the output's `timeZone`, as YYYY-MM-DD.",
});

const usedTimeZone = Schema.String.annotate({
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
      "type's style (heart rate is weighted by time). Prefer this to samples.",
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

export const HealthSampleItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the sample." }),
  start: LocalTime,
  end: LocalTime,
  value: Schema.NullOr(Schema.Finite).annotate({
    description: "A quantity's value, in `unit`. Null for category types.",
  }),
  unit: Schema.NullOr(Schema.String),
  categoryValue: Schema.NullOr(Schema.Int).annotate({
    description: "A category sample's HealthKit value (HKCategoryValue…). Null for quantities.",
  }),
  source: Schema.String.annotate({
    description: "The app or device that recorded it, e.g. an Apple Watch's name.",
  }),
}).annotate({ identifier: "HealthSampleItem" });

export const HealthSamplesResult = Schema.Struct({
  ...periodFields,
  type: healthType,
  samples: Schema.Array(HealthSampleItem).annotate({
    description: "Samples that start in the period, newest first.",
  }),
  nextCursor: Schema.NullOr(Schema.String).annotate({
    description: "Pass it as `cursor` for the next, older page; null on the last page.",
  }),
});

export const Samples = readOnly(
  Tool.make("samples", {
    description:
      "Individual samples of a quantity or category type in a period, newest first, a page at " +
      "a time. A type can have many thousands of samples a day: use metric for totals and " +
      "trends, and this only to look at particular readings.",
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

export const HealthWorkoutItem = Schema.Struct({
  id: Schema.String.annotate({ description: "HealthKit's UUID for the workout." }),
  activityType: Schema.Int.annotate({
    description: "HKWorkoutActivityType's raw value, e.g. 37 for running.",
  }),
  activity: Schema.String.annotate({ description: "The activity's name, e.g. Running." }),
  start: LocalTime,
  end: LocalTime,
  duration: Schema.Finite.annotate({ description: "Seconds of activity, excluding pauses." }),
  activeEnergy: Schema.NullOr(Schema.Finite).annotate({ description: "Kilocalories." }),
  distance: Schema.NullOr(Schema.Finite).annotate({ description: "Meters." }),
  averageHeartRate: Schema.NullOr(Schema.Finite).annotate({
    description: "Beats per minute.",
  }),
  source: Schema.String.annotate({ description: "The app or device that recorded it." }),
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
      "Workouts that started in a period, newest first, with their activity, duration, " +
      "energy, distance and average heart rate, and the period's count and total time.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthWorkoutsResult,
    failure: HealthToolError,
  }),
  "Health Workouts",
);

// -------------------------------------------------------------------------------------------------
// sleep
// -------------------------------------------------------------------------------------------------

export const HealthSleepNight = Schema.Struct({
  date: LocalDate.annotate({ description: "The day the night ends on." }),
  start: LocalTime.annotate({ description: "When the night's first sleep sample starts." }),
  end: LocalTime.annotate({ description: "When its last sleep sample ends." }),
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
    description: "Each night that ends in the period, oldest first.",
  }),
});

export const Sleep = readOnly(
  Tool.make("sleep", {
    description:
      "Sleep per night in a period: time in bed, asleep and awake, and the sleep stages (core, " +
      "deep, REM), from the person's sleep tracking.",
    parameters: Schema.Struct({ range, date, timeZone }),
    success: HealthSleepResult,
    failure: HealthToolError,
  }),
  "Health Sleep",
);

// -------------------------------------------------------------------------------------------------
// medications
// -------------------------------------------------------------------------------------------------

const adherence = Schema.Struct({
  scheduled: Schema.Int.annotate({ description: "Scheduled doses that were due." }),
  taken: Schema.Int.annotate({ description: "Of those, how many were logged as taken." }),
  asNeeded: Schema.Int.annotate({ description: "Doses taken as needed." }),
});

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
      "many scheduled doses they took over the last 7 and 30 days, and when they last took each.",
    parameters: Schema.Struct({ timeZone }),
    success: HealthMedicationsResult,
    failure: HealthToolError,
  }),
  "Health Medications",
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
  Sleep,
  Medications,
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
  sleep: "HealthSleepResult",
  medications: "HealthMedicationsResult",
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
