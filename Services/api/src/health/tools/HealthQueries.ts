import type { DateTime } from "effect";
import type { SqlRow, SqlValue, StoreSql } from "../../store/StoreSql.ts";
import { type HealthCatalogType, healthCatalogTypes } from "../HealthCatalog.ts";
import { startOfLocalDay } from "./ToolTime.ts";

// Reads of the user's store for the Health tools. They follow the Mac's `HealthDatabase` queries,
// so both MCP servers give the same answers (the conformance cases check it).

/** An iPhone that hasn't reported statistics for this long only counts if none has. */
export const statisticsSourceStalenessMillis = 14 * 24 * 60 * 60 * 1000;

export interface StatisticsDevice {
  readonly device: string;
  readonly pairedWithWatch: boolean;
  readonly reportedAt: number;
}

/** Every iPhone that reported statistics, most recently reported first (then by device ID). */
export const statisticsDevices = (sql: StoreSql): ReadonlyArray<StatisticsDevice> =>
  sql
    .exec(
      `SELECT device, paired_with_watch, reported_at FROM health_statistics_device
      ORDER BY reported_at DESC, device DESC`,
    )
    .map((row) => ({
      device: row["device"] as string,
      pairedWithWatch: row["paired_with_watch"] === 1,
      reportedAt: Number(row["reported_at"]),
    }));

/**
 * The iPhone whose statistics totals come from (`docs/decisions/health.md`): of those that
 * reported in the last 14 days, the one paired with an Apple Watch, then the most recent. If none
 * reported recently, the most recent of all. Ties go to the higher device ID. As the Mac's
 * `HealthDatabase.statisticsSource`.
 */
export const statisticsSource = (
  devices: ReadonlyArray<StatisticsDevice>,
  now: number,
): string | null => {
  const recent = devices.filter(
    (device) => device.reportedAt >= now - statisticsSourceStalenessMillis,
  );
  // Being paired with a Watch only counts among recent iPhones.
  const watch = (device: StatisticsDevice) => (recent.length > 0 && device.pairedWithWatch ? 1 : 0);
  const isBetter = (a: StatisticsDevice, b: StatisticsDevice) =>
    watch(a) !== watch(b)
      ? watch(a) > watch(b)
      : a.reportedAt !== b.reportedAt
        ? a.reportedAt > b.reportedAt
        : a.device > b.device;
  return (
    (recent.length > 0 ? recent : devices).reduce<StatisticsDevice | undefined>(
      (best, device) => (best === undefined || isBetter(device, best) ? device : best),
      undefined,
    )?.device ?? null
  );
};

export interface LatestSample {
  readonly startDate: number;
  readonly endDate: number;
  readonly value: number | null;
  readonly unit: string | null;
  readonly categoryValue: number | null;
}

const numberOrNull = (value: SqlValue | undefined) => (typeof value === "number" ? value : null);
const stringOrNull = (value: SqlValue | undefined) => (typeof value === "string" ? value : null);

/**
 * A type's most recent sample, by when it started, of those started by `now` (ties go to the
 * higher ID). Deleted samples whose rows the store hasn't swept yet are skipped (tombstones).
 */
export const latestSample = (sql: StoreSql, type: string, now: number): LatestSample | null => {
  const row = sql.exec(
    `SELECT start_date, end_date, value, unit, category_value FROM health_sample s
    WHERE type = ? AND start_date <= ?
      AND NOT EXISTS (SELECT 1 FROM tombstones t WHERE t.entity = 'health_sample' AND t.id = s.id)
    ORDER BY start_date DESC, id DESC LIMIT 1`,
    type,
    now,
  )[0];
  if (row === undefined) return null;
  return {
    startDate: Number(row["start_date"]),
    endDate: Number(row["end_date"]),
    value: numberOrNull(row["value"]),
    unit: stringOrNull(row["unit"]),
    categoryValue: numberOrNull(row["category_value"]),
  };
};

export interface CumulativeTotals {
  /** The sum over `[from, to)`, or null without a nonzero bucket. */
  readonly total: number | null;
  /** The sum over `[recentFrom, to)`, or null without a nonzero bucket. */
  readonly recent: number | null;
  readonly unit: string | null;
}

/**
 * A cumulative type's totals from one iPhone's 30-minute statistics, by when buckets start: over
 * `[from, to)`, and over the part of it from `recentFrom` (e.g. a week and its last day), in one
 * pass. Zero buckets don't count (the iPhone sends zeros to overwrite sums that are gone, which
 * the Mac's `cumulativeStatistics` skips too). The ID range uses the primary key: statistics' IDs
 * are `<device>/<type>@<bucketStart>`, and bucket starts have 13 digits from 2001 to 2286, so
 * they sort as numbers.
 */
export const cumulativeTotals = (
  sql: StoreSql,
  device: string,
  type: string,
  range: { readonly from: number; readonly recentFrom: number; readonly to: number },
): CumulativeTotals => {
  const row = sql.exec(
    `SELECT total(sum) AS total, count(*) AS buckets,
      total(CASE WHEN bucket_start >= ? THEN sum END) AS recent,
      count(CASE WHEN bucket_start >= ? THEN 1 END) AS recent_buckets,
      min(unit) AS unit
    FROM health_statistic
    WHERE id >= ? AND id < ? AND device = ? AND type = ?
      AND bucket_start >= ? AND bucket_start < ? AND sum > 0`,
    range.recentFrom,
    range.recentFrom,
    `${device}/${type}@${range.from}`,
    `${device}/${type}@${range.to}`,
    device,
    type,
    range.from,
    range.to,
  )[0];
  return {
    total: Number(row?.["buckets"] ?? 0) > 0 ? Number(row?.["total"]) : null,
    recent: Number(row?.["recent_buckets"] ?? 0) > 0 ? Number(row?.["recent"]) : null,
    unit: stringOrNull(row?.["unit"]),
  };
};

/** How many workouts start in `[from, to)`, and their total duration in seconds. */
export const workoutTotals = (sql: StoreSql, from: number, to: number) => {
  const row = sql.exec(
    `SELECT count(*) AS count, total(duration) AS duration FROM health_workout
    WHERE start_date >= ? AND start_date < ?`,
    from,
    to,
  )[0];
  return { count: Number(row?.["count"] ?? 0), duration: Number(row?.["duration"] ?? 0) };
};

/** The types pinned to Summary, in order (as the Mac's `HealthDatabase.summaryPins`). */
export const summaryPins = (sql: StoreSql): ReadonlyArray<string> =>
  sql.exec("SELECT id FROM health_pin ORDER BY position, id").map((row) => row["id"] as string);

/** Skips samples deleted since the store last swept (tombstones), for a `health_sample s`. */
const liveSample =
  "NOT EXISTS (SELECT 1 FROM tombstones t WHERE t.entity = 'health_sample' AND t.id = s.id)";

/** A type's earliest and latest records, by when they start. */
export interface TypeDates {
  readonly first: number;
  readonly last: number;
}

/** The tables of the kinds of data that aren't samples, and whether they have a `type` column. */
const kindTables: Partial<Record<HealthCatalogType["kind"], readonly [string, boolean]>> = {
  correlation: ["health_correlation", true],
  scoredAssessment: ["health_scored_assessment", true],
  workout: ["health_workout", false],
  workoutRoute: ["health_workout_route", false],
  stateOfMind: ["health_state_of_mind", false],
  audiogram: ["health_audiogram", false],
  electrocardiogram: ["health_electrocardiogram", false],
  heartbeatSeries: ["health_heartbeat_series", false],
  visionPrescription: ["health_vision_prescription", false],
  document: ["health_document", false],
  // A medication's dates are its doses'.
  medication: ["health_medication_dose", false],
  medicationDoseEvent: ["health_medication_dose", false],
};

/**
 * When a type's earliest and latest records start, from wherever its kind is stored, or null
 * without any (as the Mac's `HealthDatabase.typeDates`). Characteristics have no dates, and
 * medications without doses neither. Activity summaries are dated at the start of their day in
 * `zone`.
 */
export const typeDates = (
  sql: StoreSql,
  type: HealthCatalogType,
  zone: DateTime.TimeZone,
): TypeDates | null => {
  if (type.kind === "quantity" || type.kind === "category") {
    // Each from one end of the (type, start) key, past any tombstones.
    const end = (order: "ASC" | "DESC") =>
      sql.exec(
        `SELECT start_date FROM health_sample s WHERE type = ? AND ${liveSample}
        ORDER BY start_date ${order} LIMIT 1`,
        type.id,
      )[0]?.["start_date"];
    const first = end("ASC");
    return first === undefined ? null : { first: Number(first), last: Number(end("DESC")) };
  }
  if (type.kind === "activitySummary") {
    // Keyed by their day, which sorts by date.
    const row = sql.exec(
      "SELECT min(id) AS first, max(id) AS last FROM health_activity_summary",
    )[0];
    const first = stringOrNull(row?.["first"]);
    const last = stringOrNull(row?.["last"]);
    return first === null || last === null
      ? null
      : { first: startOfLocalDay(first, zone), last: startOfLocalDay(last, zone) };
  }
  const table = kindTables[type.kind];
  if (table === undefined) return null;
  const [name, typed] = table;
  // Two subqueries, so each reads one end of an index.
  const filter = typed ? "WHERE type = ?" : "";
  const row = sql.exec(
    `SELECT (SELECT min(start_date) FROM ${name} ${filter}) AS first,
      (SELECT max(start_date) FROM ${name} ${filter}) AS last`,
    ...(typed ? [type.id, type.id] : []),
  )[0];
  const first = numberOrNull(row?.["first"]);
  const last = numberOrNull(row?.["last"]);
  return first === null || last === null ? null : { first, last };
};

/** Whether a type has any records, as `typeDates` would find (a cheaper check of the same). */
export const hasTypeData = (sql: StoreSql, type: HealthCatalogType): boolean => {
  if (type.kind === "quantity" || type.kind === "category") {
    return (
      sql.exec(`SELECT 1 FROM health_sample s WHERE type = ? AND ${liveSample} LIMIT 1`, type.id)
        .length > 0
    );
  }
  if (type.kind === "activitySummary") {
    return sql.exec("SELECT 1 FROM health_activity_summary LIMIT 1").length > 0;
  }
  const table = kindTables[type.kind];
  if (table === undefined) return false;
  const [name, typed] = table;
  return typed
    ? sql.exec(`SELECT 1 FROM ${name} WHERE type = ? LIMIT 1`, type.id).length > 0
    : sql.exec(`SELECT 1 FROM ${name} LIMIT 1`).length > 0;
};

/**
 * When the most recent sample of any quantity or category type that has started by `now`
 * starts, or null without any. A seek of the (type, start) key per type, as the table has no
 * index on the start alone.
 */
export const latestSampleStart = (sql: StoreSql, now: number): number | null => {
  let latest: number | null = null;
  for (const type of healthCatalogTypes) {
    if (type.kind !== "quantity" && type.kind !== "category") continue;
    const start = sql.exec(
      `SELECT start_date FROM health_sample s WHERE type = ? AND start_date <= ? AND ${liveSample}
      ORDER BY start_date DESC LIMIT 1`,
      type.id,
      now,
    )[0]?.["start_date"];
    if (start !== undefined && (latest === null || Number(start) > latest)) latest = Number(start);
  }
  return latest;
};

/**
 * One iPhone's nonzero 30-minute statistics of a type that start in `[from, to)`, oldest first.
 * The ID range uses the primary key, as in `cumulativeTotals`.
 */
export const statisticBuckets = (
  sql: StoreSql,
  device: string,
  type: string,
  from: number,
  to: number,
): ReadonlyArray<{ readonly bucketStart: number; readonly sum: number }> =>
  sql
    .rows(
      `SELECT bucket_start, sum FROM health_statistic
      WHERE id >= ? AND id < ? AND device = ? AND type = ?
        AND bucket_start >= ? AND bucket_start < ? AND sum > 0
      ORDER BY bucket_start`,
      `${device}/${type}@${from}`,
      `${device}/${type}@${to}`,
      device,
      type,
      from,
      to,
    )
    .map(([bucketStart, sum]) => ({ bucketStart: Number(bucketStart), sum: Number(sum) }));

export interface SampleRow {
  readonly id: string;
  readonly startDate: number;
  readonly endDate: number;
  readonly value: number | null;
  readonly unit: string | null;
  readonly categoryValue: number | null;
  readonly sourceName: string;
  readonly sourceBundleId: string;
}

const sampleColumns =
  "id, start_date, end_date, value, unit, category_value, source_name, source_bundle_id";

const sampleRow = (row: SqlRow): SampleRow => ({
  id: row["id"] as string,
  startDate: Number(row["start_date"]),
  endDate: Number(row["end_date"]),
  value: numberOrNull(row["value"]),
  unit: stringOrNull(row["unit"]),
  categoryValue: numberOrNull(row["category_value"]),
  sourceName: row["source_name"] as string,
  sourceBundleId: row["source_bundle_id"] as string,
});

/**
 * `columns` of a type's samples that start in `[from, to)`, oldest first (then by ID), as arrays
 * of values: statistics read a year of samples, hundreds of thousands for heart rate (851-2906).
 */
const samplesStarting = (
  sql: StoreSql,
  columns: string,
  type: string,
  from: number,
  to: number,
  where = "",
) =>
  sql.rows(
    `SELECT ${columns} FROM health_sample s
    WHERE type = ? AND start_date >= ? AND start_date < ? ${where} AND ${liveSample}
    ORDER BY start_date, id`,
    type,
    from,
    to,
  );

/** A quantity type's samples with a value that start in `[from, to)`, oldest first. */
export const sampleReadings = (
  sql: StoreSql,
  type: string,
  from: number,
  to: number,
): ReadonlyArray<{
  readonly start: number;
  readonly end: number;
  readonly value: number;
  readonly source: string;
}> =>
  samplesStarting(
    sql,
    "start_date, end_date, value, source_bundle_id",
    type,
    from,
    to,
    "AND value IS NOT NULL",
  ).map(([start, end, value, source]) => ({
    start: Number(start),
    end: Number(end),
    value: Number(value),
    source: source as string,
  }));

/**
 * A cumulative type's values that start in `[from, to)`, oldest first: only when each starts and
 * its value, which is all its totals need.
 */
export const sampleSums = (
  sql: StoreSql,
  type: string,
  from: number,
  to: number,
): ReadonlyArray<{ readonly start: number; readonly value: number | null }> =>
  samplesStarting(sql, "start_date, value", type, from, to).map(([start, value]) => ({
    start: Number(start),
    value: numberOrNull(value),
  }));

/** Where a page of samples ended: its last sample's start and ID, which breaks ties. */
export interface SampleCursor {
  readonly startDate: number;
  readonly id: string;
}

/**
 * Up to `limit` of a type's samples that start in `[from, to)`, newest first (then by ID,
 * descending), after `cursor` (as the Mac's `HealthDatabase.samplePage`).
 */
export const samplePage = (
  sql: StoreSql,
  type: string,
  range: { readonly from: number; readonly to: number },
  cursor: SampleCursor | null,
  limit: number,
): ReadonlyArray<SampleRow> =>
  sql
    .exec(
      `SELECT ${sampleColumns} FROM health_sample s
      WHERE type = ? AND start_date >= ? AND start_date < ?
        ${cursor === null ? "" : "AND start_date <= ? AND (start_date < ? OR id < ?)"}
        AND ${liveSample}
      ORDER BY start_date DESC, id DESC LIMIT ?`,
      type,
      range.from,
      range.to,
      ...(cursor === null ? [] : [cursor.startDate, cursor.startDate, cursor.id]),
      limit,
    )
    .map(sampleRow);

/**
 * A type's samples that may overlap `[from, to)`: those that start before `to` and end after
 * `from`, oldest first. Without a lower bound on the start, so a long record (in bed) that
 * started well before counts.
 */
export const samplesOverlapping = (
  sql: StoreSql,
  type: string,
  from: number,
  to: number,
): ReadonlyArray<SampleRow> =>
  sql
    .exec(
      `SELECT ${sampleColumns} FROM health_sample s
      WHERE type = ? AND start_date < ? AND end_date > ? AND ${liveSample}
      ORDER BY start_date, id`,
      type,
      to,
      from,
    )
    .map(sampleRow);

export interface WorkoutRow {
  readonly id: string;
  readonly activityType: number;
  readonly startDate: number;
  readonly endDate: number;
  readonly duration: number;
  /** As stored: JSON. */
  readonly statistics: string;
  readonly sourceName: string;
}

/** Up to `limit` of the workouts that start in `[from, to)`, newest first. */
export const workoutsStarting = (
  sql: StoreSql,
  from: number,
  to: number,
  limit: number,
): ReadonlyArray<WorkoutRow> =>
  sql
    .exec(
      `SELECT id, activity_type, start_date, end_date, duration, statistics, source_name
      FROM health_workout WHERE start_date >= ? AND start_date < ?
      ORDER BY start_date DESC, id DESC LIMIT ?`,
      from,
      to,
      limit,
    )
    .map((row) => ({
      id: row["id"] as string,
      activityType: Number(row["activity_type"]),
      startDate: Number(row["start_date"]),
      endDate: Number(row["end_date"]),
      duration: Number(row["duration"]),
      statistics: row["statistics"] as string,
      sourceName: row["source_name"] as string,
    }));

export interface MedicationRow {
  readonly id: string;
  readonly name: string;
  readonly nickname: string | null;
  readonly generalForm: string;
  readonly isArchived: boolean;
  readonly hasSchedule: boolean;
}

/** Every shared medication, in no particular order. */
export const medicationRows = (sql: StoreSql): ReadonlyArray<MedicationRow> =>
  sql
    .exec(
      "SELECT id, name, nickname, general_form, is_archived, has_schedule FROM health_medication",
    )
    .map((row) => ({
      id: row["id"] as string,
      name: row["name"] as string,
      nickname: stringOrNull(row["nickname"]),
      generalForm: row["general_form"] as string,
      isArchived: row["is_archived"] === 1,
      hasSchedule: row["has_schedule"] === 1,
    }));

export interface DoseRow {
  readonly id: string;
  readonly startDate: number;
  readonly logStatus: number;
  readonly scheduleType: number;
  readonly scheduledDate: number | null;
}

/** A medication's doses whose day (when scheduled, else when logged) is from `from` on. */
export const dosesSince = (sql: StoreSql, medication: string, from: number) =>
  sql
    .exec(
      `SELECT id, start_date, log_status, schedule_type, scheduled_date FROM health_medication_dose
      WHERE medication = ? AND coalesce(scheduled_date, start_date) >= ?`,
      medication,
      from,
    )
    .map((row): DoseRow => ({
      id: row["id"] as string,
      startDate: Number(row["start_date"]),
      logStatus: Number(row["log_status"]),
      scheduleType: Number(row["schedule_type"]),
      scheduledDate: numberOrNull(row["scheduled_date"]),
    }));

/** `HKMedicationDoseEvent.LogStatus.taken`'s raw value. */
export const doseTaken = 4;

/** When a dose of the medication was last logged as taken, or null if none was. */
export const lastTaken = (sql: StoreSql, medication: string): number | null =>
  numberOrNull(
    sql.exec(
      `SELECT max(start_date) AS start FROM health_medication_dose
      WHERE medication = ? AND log_status = ?`,
      medication,
      doseTaken,
    )[0]?.["start"],
  );

/** Every synced characteristic's value as stored (JSON), by type identifier, in ID order. */
export const characteristicValues = (sql: StoreSql): ReadonlyArray<readonly [string, string]> =>
  sql
    .exec("SELECT id, value FROM health_characteristic ORDER BY id")
    .map((row) => [row["id"] as string, row["value"] as string] as const);

export interface VisionPrescriptionRow {
  readonly id: string;
  readonly startDate: number;
  readonly prescriptionType: number;
  readonly expirationDate: number | null;
  readonly brand: string | null;
  /** As stored: JSON, or null. */
  readonly rightEye: string | null;
  readonly leftEye: string | null;
}

/** Every vision prescription, newest issued first. */
export const visionPrescriptions = (sql: StoreSql): ReadonlyArray<VisionPrescriptionRow> =>
  sql
    .exec(
      `SELECT id, start_date, prescription_type, expiration_date, brand, right_eye, left_eye
      FROM health_vision_prescription ORDER BY start_date DESC, id DESC`,
    )
    .map((row) => ({
      id: row["id"] as string,
      startDate: Number(row["start_date"]),
      prescriptionType: Number(row["prescription_type"]),
      expirationDate: numberOrNull(row["expiration_date"]),
      brand: stringOrNull(row["brand"]),
      rightEye: stringOrNull(row["right_eye"]),
      leftEye: stringOrNull(row["left_eye"]),
    }));
