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

/** A server device ID (`src/core/Ids.ts`). */
const deviceId = "dev_[0-9a-z]{26}";
const quantityType = "HKQuantityTypeIdentifier[A-Za-z]+";

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
  checkRow: (row) =>
    typeof row.bucketStart === "number" && row.bucketStart % statisticsBucketMillis !== 0
      ? "bucketStart must be a multiple of 30 minutes"
      : undefined,
});

/**
 * One iPhone's statistics status (`self`, stored under its device ID). The Mac uses the
 * statistics of the iPhone paired with an Apple Watch, otherwise of the one that reported most
 * recently, so a phone that's behind on Health's iCloud sync can't overwrite complete numbers.
 */
export const HealthStatisticsDevice = defineEntity("health_statistics_device", {
  clientWritable: false,
  id: new RegExp(`^${deviceId}$`),
  deviceScoped: { id: /^self$/ },
  fields: {
    device: Column.text,
    /** Whether the iPhone is paired with an Apple Watch (`WCSession.isPaired`). */
    pairedWithWatch: Column.boolean,
    /** When it last uploaded statistics (Unix milliseconds). */
    reportedAt: Column.integer,
  },
});

export const healthEntities = [
  HealthSample,
  HealthCorrelation,
  HealthCharacteristic,
  HealthActivitySummary,
  HealthStatistic,
  HealthStatisticsDevice,
] as const;
