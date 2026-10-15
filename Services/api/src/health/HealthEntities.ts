import { idPattern } from "../core/Ids.ts";
import { Column, defineEntity } from "../store/Entities.ts";

// Generic HealthKit data in the user's store. Records are keyed by HealthKit's UUID, lowercased
// (and checked), so the same sample uploaded by two iPhones is one record. Times are Unix
// milliseconds.

/** `HKObject.uuid`, lowercased. */
const healthKitUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Where a sample or correlation came from. */
const provenance = {
  /** `HKSource.name`, e.g. "Alexandru's Apple Watch". */
  sourceName: Column.text,
  /** `HKSource.bundleIdentifier`. */
  sourceBundleId: Column.text,
  /** `HKSourceRevision`: `version`, `productType`, `operatingSystemVersion`. */
  sourceRevision: Column.nullable(Column.json),
  /** `HKDevice`'s properties, when HealthKit has them. */
  device: Column.nullable(Column.json),
  /** The sample's metadata, with HealthKit's keys (e.g. `HKTimeZone`). */
  metadata: Column.nullable(Column.json),
};

/** Quantity and category samples. */
export const HealthSample = defineEntity("health_sample", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    /** The HealthKit type identifier, e.g. `HKQuantityTypeIdentifierStepCount`. */
    type: Column.text,
    startDate: Column.integer,
    endDate: Column.integer,
    /** A quantity sample's value, in the type's unit from the Swift `HealthCatalog` module. */
    value: Column.nullable(Column.real),
    /** The unit `value` is in, as an `HKUnit` string. */
    unit: Column.nullable(Column.text),
    /** A category sample's value (`HKCategoryValue…`). */
    categoryValue: Column.nullable(Column.integer),
    /** The correlation (blood pressure, food) the sample belongs to, if any. */
    correlationId: Column.nullable(Column.text),
    ...provenance,
  },
});

/** Blood pressure and food correlations. Their member samples point at them. */
export const HealthCorrelation = defineEntity("health_correlation", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    type: Column.text,
    startDate: Column.integer,
    endDate: Column.integer,
    ...provenance,
  },
});

/**
 * Workouts (`HKWorkout`): the overall activity type and times, and as JSON what HealthKit nests in
 * them: activities (the legs of a multisport workout), events (pauses, laps, segments, markers)
 * and per-type statistics. Routes are separate (851-2566).
 */
export const HealthWorkout = defineEntity("health_workout", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    /** `HKWorkoutActivityType`'s raw value, e.g. 37 for running. */
    activityType: Column.integer,
    startDate: Column.integer,
    endDate: Column.integer,
    /** Seconds of activity, excluding pauses. */
    duration: Column.real,
    /**
     * `HKWorkoutActivity`s, in order: `{ id, activityType, startDate, endDate, duration,
     * metadata, statistics }`. Often empty: HealthKit only has them for workouts recorded with
     * activities (e.g. multisport), so read `activityType` and `statistics` for the whole.
     */
    activities: Column.json,
    /** `HKWorkoutEvent`s, in order: `{ type, startDate, endDate, metadata }`. */
    events: Column.json,
    /**
     * By quantity type identifier: `{ unit, sum, average, minimum, maximum, mostRecent }`, each
     * in the type's unit from the Swift `HealthCatalog` module, or null.
     */
    statistics: Column.json,
    ...provenance,
  },
  // The JSON fields' shapes, so a client can rely on them.
  checkRow: (_, row) => {
    if (!Array.isArray(row.activities)) return "activities must be an array";
    if (!Array.isArray(row.events)) return "events must be an array";
    const { statistics } = row;
    if (typeof statistics !== "object" || statistics === null || Array.isArray(statistics)) {
      return "statistics must be an object";
    }
    return undefined;
  },
});

/** Whether a field is a list of HealthKit enum raw values. */
const isRawValues = (value: unknown) =>
  Array.isArray(value) && value.every((element) => Number.isInteger(element));

/** State of Mind logs (`HKStateOfMind`): a momentary emotion or a daily mood. */
export const HealthStateOfMind = defineEntity("health_state_of_mind", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    startDate: Column.integer,
    endDate: Column.integer,
    /** `HKStateOfMind.Kind`'s raw value: 1 a momentary emotion, 2 a daily mood. */
    kind: Column.integer,
    /** How pleasant, from -1 (very unpleasant) to 1 (very pleasant). */
    valence: Column.real,
    /** `HKStateOfMind.ValenceClassification`'s raw value. */
    valenceClassification: Column.integer,
    /** `HKStateOfMind.Label` raw values, e.g. 4 for "anxious". */
    labels: Column.json,
    /** `HKStateOfMind.Association` raw values, e.g. 5 for "family". */
    associations: Column.json,
    ...provenance,
  },
  checkRow: (_, row) => {
    if (!isRawValues(row.labels)) return "labels must be an array of integers";
    if (!isRawValues(row.associations)) return "associations must be an array of integers";
    const { valence } = row;
    if (typeof valence !== "number" || valence < -1 || valence > 1) {
      return "valence must be from -1 to 1";
    }
    return undefined;
  },
});

/** Scored mental health assessments (`HKScoredAssessment`): GAD-7 (anxiety) and PHQ-9 (depression). */
export const HealthScoredAssessment = defineEntity("health_scored_assessment", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    /** The type identifier, e.g. `HKScoredAssessmentTypeIdentifierGAD7`. */
    type: Column.text,
    startDate: Column.integer,
    endDate: Column.integer,
    score: Column.integer,
    /** The assessment's risk raw value (`HKGAD7Assessment.Risk`, `HKPHQ9Assessment.Risk`). */
    risk: Column.integer,
    /** Each question's answer raw value, in order. */
    answers: Column.json,
    ...provenance,
  },
  checkRow: (_, row) =>
    isRawValues(row.answers) ? undefined : "answers must be an array of integers",
});

/**
 * Characteristics (date of birth, sex, blood type, skin type, wheelchair use, move mode), keyed by
 * their type identifier.
 */
export const HealthCharacteristic = defineEntity("health_characteristic", {
  clientWritable: false,
  id: /^HKCharacteristicTypeIdentifier[A-Za-z]+$/,
  fields: {
    /** E.g. `{ "year": 1990, "month": 4, "day": 2 }` for date of birth, or an enum case's name. */
    value: Column.json,
  },
});

/** The Activity rings for one day, keyed by the day (`YYYY-MM-DD`, in the iPhone's calendar). */
export const HealthActivitySummary = defineEntity("health_activity_summary", {
  clientWritable: false,
  id: /^\d{4}-\d{2}-\d{2}$/,
  fields: {
    /** Kilocalories. */
    activeEnergyBurned: Column.nullable(Column.real),
    activeEnergyBurnedGoal: Column.nullable(Column.real),
    /** Minutes, for move-time mode. */
    appleMoveTime: Column.nullable(Column.real),
    appleMoveTimeGoal: Column.nullable(Column.real),
    /** Minutes. */
    appleExerciseTime: Column.nullable(Column.real),
    appleExerciseTimeGoal: Column.nullable(Column.real),
    /** Hours. */
    appleStandHours: Column.nullable(Column.real),
    appleStandHoursGoal: Column.nullable(Column.real),
    /** `activeEnergy` or `appleMoveTime`. */
    activityMoveMode: Column.nullable(Column.text),
    /** Whether the rings were paused that day. */
    paused: Column.nullable(Column.boolean),
  },
});

/** Statistics buckets are 30 minutes, starting on UTC half-hours (Unix milliseconds). */
export const statisticsBucketMillis = 30 * 60 * 1000;

const deviceId = idPattern("dev");
/** Quantity type identifiers, some with digits (`HKQuantityTypeIdentifierDietaryVitaminB12`). */
const quantityType = "HKQuantityTypeIdentifier[A-Za-z0-9]+";

/**
 * A cumulative type's sum over one 30-minute bucket, as one iPhone's HealthKit computed it. Health
 * de-duplicates overlapping sources (iPhone and Watch steps) in ways only HealthKit can, so the
 * Mac sums these instead of raw samples. Each iPhone uploads its own: `<type>@<bucketStart>`,
 * stored as `<device>/<type>@<bucketStart>`.
 */
export const HealthStatistic = defineEntity("health_statistic", {
  clientWritable: false,
  id: new RegExp(`^${deviceId}/${quantityType}@\\d+$`),
  deviceScoped: { id: new RegExp(`^${quantityType}@\\d+$`) },
  fields: {
    /** The iPhone that computed it. */
    device: Column.text,
    type: Column.text,
    /** The bucket's start, a multiple of `statisticsBucketMillis`. */
    bucketStart: Column.integer,
    sum: Column.real,
    /** The unit `sum` is in, as an `HKUnit` string. */
    unit: Column.text,
  },
  checkRow: (id, row) => {
    if (typeof row.bucketStart !== "number" || row.bucketStart % statisticsBucketMillis !== 0) {
      return "bucketStart must be a multiple of 30 minutes";
    }
    // One key per device, type and bucket.
    const expected = `${String(row.device)}/${String(row.type)}@${row.bucketStart}`;
    return id === expected ? undefined : `The ID must be ${expected}`;
  },
});

/**
 * One iPhone's statistics status (`self`, stored under its device ID). The Mac uses the
 * statistics of the iPhone paired with an Apple Watch, otherwise of the one that reported most
 * recently, so a phone that's behind on Health's iCloud sync can't overwrite complete numbers.
 */
export const HealthStatisticsDevice = defineEntity("health_statistics_device", {
  clientWritable: false,
  id: new RegExp(`^${deviceId}$`),
  deviceScoped: { id: /^self$/, stampedAt: "reportedAt" },
  fields: {
    device: Column.text,
    /** Whether the iPhone is paired with an Apple Watch (`WCSession.isPaired`). */
    pairedWithWatch: Column.boolean,
    /** When the server last applied its report (Unix milliseconds), not the iPhone's clock. */
    reportedAt: Column.integer,
  },
  checkRow: (id, row) => (id === row.device ? undefined : "The ID must be the device"),
});

export const healthEntities = [
  HealthSample,
  HealthCorrelation,
  HealthCharacteristic,
  HealthActivitySummary,
  HealthStatistic,
  HealthStatisticsDevice,
  HealthWorkout,
  HealthStateOfMind,
  HealthScoredAssessment,
] as const;
