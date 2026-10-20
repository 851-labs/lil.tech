import { Schema } from "effect";
import { idPattern } from "../core/Ids.ts";
import { Column, defineEntity } from "../store/Entities.ts";
import { HealthBlobHash } from "./HealthBlobs.ts";

const isBlobHash = Schema.is(HealthBlobHash);

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
  /**
   * `HKSourceRevision`: `version`, `productType`, `operatingSystemVersion`. Only from iPhones
   * that don't send `provenance`.
   */
  sourceRevision: Column.nullable(Column.json),
  /** `HKDevice`'s properties, when HealthKit has them. Only from iPhones that don't send `provenance`. */
  device: Column.nullable(Column.json),
  /** The sample's metadata, with HealthKit's keys (e.g. `HKTimeZone`). */
  metadata: Column.nullable(Column.json),
  /**
   * The `health_provenance` record with the record's `sourceRevision` and `device` (851-2674).
   * They repeat across nearly all of a user's samples, so they're stored once.
   */
  provenance: Column.nullable(Column.text),
};

/**
 * A sample's source revision and device, which most of a user's samples share (851-2674). The ID
 * is a hash of the two, so the same pair is one record, made by the iPhone.
 */
export const HealthProvenance = defineEntity("health_provenance", {
  clientWritable: false,
  id: /^[0-9a-f]{32}$/,
  fields: {
    /** `HKSourceRevision`: `version`, `productType`, `operatingSystemVersion`. */
    sourceRevision: Column.nullable(Column.json),
    /** `HKDevice`'s properties, when HealthKit has them. */
    device: Column.nullable(Column.json),
  },
});

/**
 * Quantity and category samples. Stored by type and start date (HealthKit never changes a
 * sample's), so a backfill, a type at a time in time order, writes next to itself.
 */
export const HealthSample = defineEntity("health_sample", {
  clientWritable: false,
  id: healthKitUUID,
  key: ["type", "startDate"],
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

/**
 * Audiograms (`HKAudiogramSample`): hearing sensitivity at each tested frequency, per ear.
 */
export const HealthAudiogram = defineEntity("health_audiogram", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    startDate: Column.integer,
    endDate: Column.integer,
    /**
     * By frequency, ascending: `{ frequency, tests }`, `frequency` in Hz. Each test is
     * `{ side, type, masked, sensitivity, clampingLower, clampingUpper }`: `side` and `type` are
     * `HKAudiogramSensitivityTestSide` and `HKAudiogramConductionType` raw values, and the
     * sensitivity and clamping bounds are in dBHL (the bounds may be null).
     */
    points: Column.json,
    ...provenance,
  },
  checkRow: (_, row) => checkAudiogramPoints(row.points),
});

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** Checks an audiogram's points have the shape `HealthAudiogram` documents. */
const checkAudiogramPoints = (points: unknown): string | undefined => {
  if (!Array.isArray(points)) return "points must be an array";
  let previous = -Infinity;
  for (const point of points) {
    if (!isObject(point) || typeof point.frequency !== "number" || !Array.isArray(point.tests)) {
      return "each point must be { frequency, tests }";
    }
    if (point.frequency <= previous) return "frequencies must be unique and ascending";
    previous = point.frequency;
    for (const test of point.tests) {
      const ok =
        isObject(test) &&
        Number.isInteger(test.side) &&
        Number.isInteger(test.type) &&
        typeof test.masked === "boolean" &&
        typeof test.sensitivity === "number" &&
        (test.clampingLower === null || typeof test.clampingLower === "number") &&
        (test.clampingUpper === null || typeof test.clampingUpper === "number");
      if (!ok)
        return "each test must be { side, type, masked, sensitivity, clampingLower, clampingUpper }";
    }
  }
  return undefined;
};

/**
 * Glasses and contact lens prescriptions (`HKVisionPrescription`, 851-2572). Health shares them one
 * by one, as the person picks them (per-object read authorization).
 */
export const HealthVisionPrescription = defineEntity("health_vision_prescription", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    /** When it was issued, as both the sample's start and end. */
    startDate: Column.integer,
    endDate: Column.integer,
    /** `HKVisionPrescriptionType`'s raw value: 1 glasses, 2 contacts. */
    prescriptionType: Column.integer,
    expirationDate: Column.nullable(Column.integer),
    /** A contacts prescription's lens brand. */
    brand: Column.nullable(Column.text),
    /**
     * Each eye's lens, or null for an eye it doesn't cover: `sphere`, `cylinder`, `axis` and
     * `addPower` (diopters, the axis in degrees) for both kinds. Glasses add `vertexDistance`,
     * `farPupillaryDistance` and `nearPupillaryDistance` (mm) and `prism` (`{ amount, angle,
     * verticalAmount, verticalBase, horizontalAmount, horizontalBase }`, prism diopters and
     * degrees, the bases `HKPrismBase` raw values); contacts add `baseCurve` and `diameter` (mm).
     * Values a prescription doesn't give are null.
     */
    rightEye: Column.nullable(Column.json),
    leftEye: Column.nullable(Column.json),
    ...provenance,
  },
  checkRow: (_, row) => checkVisionPrescription(row.prescriptionType, [row.rightEye, row.leftEye]),
});

/** Whether every value of an object is a number or null. */
const numbersOrNull = (value: Record<string, unknown>) =>
  Object.values(value).every((field) => field === null || typeof field === "number");

/** A prism's amounts and angle (numbers, or null if in another unit) and its bases (raw values). */
const isPrism = (prism: unknown) =>
  isObject(prism) &&
  ["amount", "angle", "verticalAmount", "horizontalAmount"].every(
    (key) => prism[key] === null || typeof prism[key] === "number",
  ) &&
  Number.isInteger(prism.verticalBase) &&
  Number.isInteger(prism.horizontalBase);

/** Checks a vision prescription has the shape `HealthVisionPrescription` documents. */
const checkVisionPrescription = (
  prescriptionType: unknown,
  eyes: ReadonlyArray<unknown>,
): string | undefined => {
  if (prescriptionType !== 1 && prescriptionType !== 2) {
    return "prescriptionType must be 1 (glasses) or 2 (contacts)";
  }
  for (const eye of eyes) {
    if (eye === null) continue;
    if (!isObject(eye) || typeof eye.sphere !== "number") {
      return "each eye must be null or a lens with its sphere";
    }
    const { prism, ...values } = eye;
    if (!numbersOrNull(values)) return "a lens's values must be numbers or null";
    if (prism !== undefined && prism !== null && !isPrism(prism)) {
      return "a lens's prism must be null or { amount, angle, verticalAmount, verticalBase, horizontalAmount, horizontalBase }";
    }
  }
  return undefined;
};

/**
 * A medication concept's ID: the SHA-256 (lowercase hex) the iPhone makes from HealthKit's
 * `HKHealthConceptIdentifier`, which has no public value of its own.
 */
const medicationConceptId = /^[0-9a-f]{64}$/;

/**
 * Medications (`HKUserAnnotatedMedication`, 851-2571), current and archived, that the person
 * shares one by one (per-object read authorization). Keyed by their concept's ID, which their
 * doses refer to. They aren't samples, so they have no dates or source.
 */
export const HealthMedication = defineEntity("health_medication", {
  clientWritable: false,
  id: medicationConceptId,
  fields: {
    /** Its name, as Health shows it (`HKMedicationConcept.displayText`). */
    name: Column.text,
    /** The name the person gave it, if any. */
    nickname: Column.nullable(Column.text),
    /** `HKMedicationGeneralForm`'s raw value, e.g. `tablet`. Any string, so new forms go through. */
    generalForm: Column.text,
    isArchived: Column.boolean,
    hasSchedule: Column.boolean,
    /**
     * Codes for it in clinical systems (`HKClinicalCoding`), e.g. RxNorm's: `[{ system, version,
     * code }]`, `version` possibly null.
     */
    codings: Column.json,
  },
  checkRow: (_, row) => checkCodings(row.codings),
});

/** Checks a medication's codings have the shape `HealthMedication` documents. */
const checkCodings = (codings: unknown): string | undefined => {
  if (!Array.isArray(codings)) return "codings must be an array";
  for (const coding of codings) {
    const ok =
      isObject(coding) &&
      typeof coding.system === "string" &&
      typeof coding.code === "string" &&
      (coding.version === null || typeof coding.version === "string");
    if (!ok) return "each coding must be { system, version, code }";
  }
  return undefined;
};

/**
 * Medication dose events (`HKMedicationDoseEvent`, 851-2571): a dose logged as taken or skipped,
 * or a scheduled one that wasn't logged. Health shares those of the medications the person
 * shares. Enum fields are HealthKit's raw values, any integer, so values a later iOS adds go
 * through.
 */
export const HealthMedicationDose = defineEntity("health_medication_dose", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    startDate: Column.integer,
    endDate: Column.integer,
    /** The `health_medication` it's a dose of, by its concept's ID. */
    medication: Column.text,
    /** `HKMedicationDoseEvent.LogStatus`'s raw value, e.g. 4 for taken, 5 for skipped. */
    logStatus: Column.integer,
    /** `HKMedicationDoseEvent.ScheduleType`'s raw value: 1 as needed, 2 scheduled. */
    scheduleType: Column.integer,
    /** When it was scheduled for, if it was. */
    scheduledDate: Column.nullable(Column.integer),
    /** The dose scheduled and the dose logged, in `unit`. */
    scheduledDoseQuantity: Column.nullable(Column.real),
    doseQuantity: Column.nullable(Column.real),
    /** The quantities' unit, as an `HKUnit` string. */
    unit: Column.text,
    ...provenance,
  },
  checkRow: (_, row) =>
    typeof row.medication === "string" && medicationConceptId.test(row.medication)
      ? undefined
      : "medication must be a medication's concept ID",
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
 * ECG recordings (`HKElectrocardiogram`). The voltages are a blob (`src/health/HealthBlobs.ts`):
 * one little-endian 32-bit float per measurement, in microvolts, Apple Watch's lead I, at
 * `samplingFrequency` Hz from `startDate`.
 */
export const HealthElectrocardiogram = defineEntity("health_electrocardiogram", {
  clientWritable: false,
  id: healthKitUUID,
  blobs: ["voltages"],
  fields: {
    startDate: Column.integer,
    endDate: Column.integer,
    /** `HKElectrocardiogram.Classification` raw value. */
    classification: Column.integer,
    /** `HKElectrocardiogram.SymptomsStatus` raw value. The symptoms are category samples. */
    symptomsStatus: Column.integer,
    /** Beats per minute. */
    averageHeartRate: Column.nullable(Column.real),
    /** Hz. */
    samplingFrequency: Column.nullable(Column.real),
    voltageCount: Column.integer,
    /** The voltages blob's SHA-256, or `null` without measurements. */
    voltages: Column.nullable(Column.text),
    ...provenance,
  },
  checkRow: (_, row) => {
    if (row.voltages !== null && !isBlobHash(row.voltages)) {
      return "voltages must be a blob's SHA-256 or null";
    }
    if (typeof row.voltageCount !== "number" || row.voltageCount < 0) {
      return "voltageCount can't be negative";
    }
    // Rows are full records, so the two always arrive together.
    return row.voltageCount > 0 === (row.voltages !== null)
      ? undefined
      : "a recording has a voltages blob exactly when it has measurements";
  },
});

/**
 * Workout routes (`HKWorkoutRoute`): the locations recorded during a workout. The locations are a blob
 * (`src/health/HealthBlobs.ts`), 44 bytes each, little-endian: the time (Unix seconds), latitude
 * and longitude (degrees) as 64-bit floats, then altitude, horizontal and vertical accuracy (m),
 * speed (m/s) and course (degrees) as 32-bit floats. Accuracies, speed and course are negative
 * when unknown, as in Core Location. A later format would add a `locationsFormat` field: rows
 * without one are this format.
 */
export const HealthWorkoutRoute = defineEntity("health_workout_route", {
  clientWritable: false,
  id: healthKitUUID,
  blobs: ["locations"],
  fields: {
    startDate: Column.integer,
    endDate: Column.integer,
    /** The workout's ID, found through HealthKit's workout-to-routes query, or `null`. */
    workout: Column.nullable(Column.text),
    locationCount: Column.integer,
    /** The locations blob's SHA-256, or `null` without locations. */
    locations: Column.nullable(Column.text),
    ...provenance,
  },
  checkRow: (_, row) => {
    if (row.locations !== null && !isBlobHash(row.locations)) {
      return "locations must be a blob's SHA-256 or null";
    }
    if (
      row.workout !== null &&
      !(typeof row.workout === "string" && healthKitUUID.test(row.workout))
    ) {
      return "workout must be a lowercase HealthKit UUID or null";
    }
    if (typeof row.locationCount !== "number" || row.locationCount < 0) {
      return "locationCount can't be negative";
    }
    return row.locationCount > 0 === (row.locations !== null)
      ? undefined
      : "a route has a locations blob exactly when it has locations";
  },
});

/**
 * Heartbeat series (`HKHeartbeatSeriesSample`): the beat-to-beat timings behind Apple Watch's
 * heart rate variability readings, about a minute and a hundred beats each, so they're kept in
 * the row rather than as a blob.
 */
export const HealthHeartbeatSeries = defineEntity("health_heartbeat_series", {
  clientWritable: false,
  id: healthKitUUID,
  fields: {
    startDate: Column.integer,
    endDate: Column.integer,
    /** Each beat's time, in seconds since `startDate`, in order (rounded to 0.1 ms). */
    beats: Column.json,
    /** The indices of the beats preceded by a gap (beats HealthKit couldn't measure). */
    gaps: Column.json,
    ...provenance,
  },
  checkRow: (_, row) => checkHeartbeats(row.beats, row.gaps),
});

/** Checks a heartbeat series' beats and gaps have the shape `HealthHeartbeatSeries` documents. */
const checkHeartbeats = (beats: unknown, gaps: unknown): string | undefined => {
  if (!Array.isArray(beats)) return "beats must be an array";
  let previous = -Infinity;
  for (const beat of beats) {
    if (typeof beat !== "number" || beat < 0 || beat < previous) {
      return "beats must be non-negative seconds, in order";
    }
    previous = beat;
  }
  if (!isRawValues(gaps)) return "gaps must be an array of integers";
  let previousGap = -1;
  for (const gap of gaps as Array<number>) {
    if (gap <= previousGap || gap >= beats.length) return "gaps must be ascending indices of beats";
    previousGap = gap;
  }
  return undefined;
};

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
  HealthProvenance,
  HealthSample,
  HealthCorrelation,
  HealthCharacteristic,
  HealthActivitySummary,
  HealthStatistic,
  HealthStatisticsDevice,
  HealthWorkout,
  HealthStateOfMind,
  HealthScoredAssessment,
  HealthAudiogram,
  HealthElectrocardiogram,
  HealthHeartbeatSeries,
  HealthWorkoutRoute,
  HealthVisionPrescription,
  HealthMedication,
  HealthMedicationDose,
] as const;
