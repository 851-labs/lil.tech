import type { DateTime } from "effect";
import type { SqlRow, SqlValue, StoreSql } from "../../store/StoreSql.ts";
import { type HealthCatalogType, healthCatalogTypes } from "../HealthCatalog.ts";
import { statisticsBucketMillis } from "../HealthEntities.ts";
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
  readonly id: string;
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
    `SELECT id, start_date, end_date, value, unit, category_value FROM health_sample s
    WHERE type = ? AND start_date <= ?
      AND NOT EXISTS (SELECT 1 FROM tombstones t WHERE t.entity = 'health_sample' AND t.id = s.id)
    ORDER BY start_date DESC, id DESC LIMIT 1`,
    type,
    now,
  )[0];
  if (row === undefined) return null;
  return {
    id: row["id"] as string,
    startDate: Number(row["start_date"]),
    endDate: Number(row["end_date"]),
    value: numberOrNull(row["value"]),
    unit: stringOrNull(row["unit"]),
    categoryValue: numberOrNull(row["category_value"]),
  };
};

/**
 * A type's latest reading started by `now` (851-4171): `latestSample`, with a discrete series'
 * most recent value in place of the series' own (its value, start and end), since HealthKit's
 * value for a whole heart rate series is its average, which isn't a reading anyone took; or a
 * series that started before it (up to `seriesLookbackMillis`) whose most recent value is later
 * (a workout's, past a strap's reading during it). Ties go to the higher ID. The Mac's
 * `HealthDatabase.latestReading`.
 */
export const latestReading = (sql: StoreSql, type: string, now: number): LatestSample | null => {
  const sample = latestSample(sql, type, now);
  if (sample === null) return null;
  const own = sql.exec(
    `SELECT most_recent, most_recent_start_date, most_recent_end_date
    FROM health_quantity_series WHERE id = ? AND most_recent IS NOT NULL`,
    sample.id,
  )[0];
  const ownStart = numberOrNull(own?.["most_recent_start_date"]) ?? sample.startDate;
  const latest: LatestSample =
    own === undefined
      ? sample
      : {
          ...sample,
          value: numberOrNull(own["most_recent"]),
          startDate: ownStart,
          endDate: numberOrNull(own["most_recent_end_date"]) ?? ownStart,
        };
  const later = sql.exec(
    `SELECT s.id, s.unit, q.most_recent, q.most_recent_start_date, q.most_recent_end_date
    FROM health_quantity_series q JOIN health_sample s ON s.id = q.id
    WHERE q.type = ? AND q.start_date >= ? AND q.start_date <= ? AND q.most_recent IS NOT NULL
      AND q.most_recent_start_date > ? AND q.most_recent_start_date <= ? AND ${liveSample}
    ORDER BY q.most_recent_start_date DESC, s.id DESC LIMIT 1`,
    type,
    sample.startDate - seriesLookbackMillis,
    sample.startDate,
    latest.startDate,
    now,
  )[0];
  if (later === undefined) return latest;
  const startDate = Number(later["most_recent_start_date"]);
  return {
    id: later["id"] as string,
    startDate,
    endDate: numberOrNull(later["most_recent_end_date"]) ?? startDate,
    value: numberOrNull(later["most_recent"]),
    unit: stringOrNull(later["unit"]),
    categoryValue: null,
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

/** Skips samples deleted since the store last swept (tombstones), for a `health_sample s`. */
export const liveSample =
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

/** A cumulative type's total over one bucket (an hour, a day…), by when the bucket starts. */
export interface BucketTotal {
  readonly start: number;
  readonly sum: number;
}

/**
 * A cumulative type's totals per bucket in `[from, to)` (each placed by `startOf`, which rows reach
 * in time order), from the statistics source's 30-minute buckets and, past the last of them (no
 * statistics at all, or samples synced before their buckets), the samples' own values, oldest
 * first, as the Mac's `HealthDatabase.cumulativeTotals`. Buckets without data are left out, and so
 * are empty statistics. Each bucket adds its statistics, then its samples, in order, as the Mac
 * does.
 */
export const cumulativeTotalsBy = (
  sql: StoreSql,
  type: string,
  range: { readonly start: number; readonly end: number },
  startOf: (millis: number) => number,
  now: number,
): Array<BucketTotal> => {
  const source = statisticsSource(statisticsDevices(sql), now);
  const buckets =
    source === null ? [] : statisticBuckets(sql, source, type, range.start, range.end);
  const sums = new Map<number, number>();
  const add = (millis: number, value: number) => {
    const start = startOf(millis);
    sums.set(start, (sums.get(start) ?? 0) + value);
  };
  for (const { bucketStart, sum } of buckets) add(bucketStart, sum);
  // Empty buckets don't count as covered: samples that arrived before their sums still show.
  const lastBucket = buckets.at(-1);
  const covered =
    lastBucket === undefined ? range.start : lastBucket.bucketStart + statisticsBucketMillis;
  for (const sample of sampleSums(sql, type, covered, range.end)) {
    add(sample.start, sample.value ?? 0);
  }
  return [...sums.entries()]
    .map(([start, sum]) => ({ start, sum }))
    .sort((a, b) => a.start - b.start);
};

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
 * A sample or correlation as `samples` lists it (851-4166): its row, with its source revision,
 * device and metadata as JSON, the revision and device from its `health_provenance` record when
 * the row has none (as the Mac's `withProvenance`).
 */
export interface DetailedSampleRow extends SampleRow {
  readonly sourceRevision: string | null;
  readonly device: string | null;
  readonly metadata: string | null;
}

const detailedRow = (row: SqlRow): DetailedSampleRow => ({
  ...sampleRow(row),
  sourceRevision: stringOrNull(row["source_revision"]),
  device: stringOrNull(row["device"]),
  metadata: stringOrNull(row["metadata"]),
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

// Quantity series as readings (851-4171), as the Mac's `QuantitySeriesReadings.swift` reads
// them: a sample whose `count` is over 1 (a Watch's heart rate in a workout) keeps its values in
// `health_quantity_series` (851-4149), and statistics read each value as a reading of its own, at
// its own time, as HealthKit's statistics split a series. The cards' engine can share them
// (851-4172).

/** A reading of a quantity type: a sample with a value, or one of a series' values. */
export interface QuantityReading {
  /** Unix milliseconds. */
  readonly start: number;
  readonly end: number;
  readonly value: number;
  /** The source's bundle ID: each source is its own series for time weighting. */
  readonly source: string;
}

/**
 * How long after its start a series' values count, in milliseconds: a range reads the series
 * that started this long before it too, and values later than that (or after the sample's end)
 * don't count anywhere, so what a range reads doesn't depend on where it starts. The iPhone
 * uploads at most 20,000 values a series: a week of them every 30 s. The Mac's
 * `HealthDatabase.seriesLookback`.
 */
export const seriesLookbackMillis = 7 * 24 * 60 * 60 * 1000;

/** A quantity series' values: each one's start and duration in seconds since the sample's start. */
export interface QuantitySeriesValues {
  readonly times: ReadonlyArray<number>;
  readonly durations: ReadonlyArray<number>;
  readonly values: ReadonlyArray<number>;
}

const numberArray = (json: SqlValue | undefined): ReadonlyArray<number> | null => {
  if (typeof json !== "string") return null;
  try {
    const parsed: unknown = JSON.parse(json);
    return Array.isArray(parsed) && parsed.every((item) => typeof item === "number")
      ? (parsed as ReadonlyArray<number>)
      : null;
  } catch {
    return null;
  }
};

/** Seconds a series' time or duration can be: from 0 to about 31 years, as on the Mac. */
const isSeriesSeconds = (seconds: number) => seconds >= 0 && seconds <= 1e9;

/**
 * A series' values from its row's JSON arrays, or null when the iPhone didn't upload them (more
 * than `HealthEncoder.maxSeriesValues`), or they're empty, don't have one entry each, or have a
 * time or duration that isn't from 0 to 1e9 s.
 */
export const quantitySeriesValues = (
  times: SqlValue | undefined,
  durations: SqlValue | undefined,
  values: SqlValue | undefined,
): QuantitySeriesValues | null => {
  const [starts, lengths, numbers] = [
    numberArray(times),
    numberArray(durations),
    numberArray(values),
  ];
  return starts === null ||
    lengths === null ||
    numbers === null ||
    starts.length === 0 ||
    lengths.length !== starts.length ||
    numbers.length !== starts.length ||
    !starts.every(isSeriesSeconds) ||
    !lengths.every(isSeriesSeconds)
    ? null
    : { times: starts, durations: lengths, values: numbers };
};

/** When value `index` starts and ends (Unix milliseconds): its seconds to the millisecond. */
export const seriesValueInterval = (
  series: QuantitySeriesValues,
  index: number,
  sampleStart: number,
) => {
  const start = sampleStart + Math.round(series.times[index]! * 1000);
  return { start, end: start + Math.round(series.durations[index]! * 1000) };
};

/** A sample that's a quantity series, with what statistics need of it. */
export interface QuantitySeriesSample {
  readonly id: string;
  readonly start: number;
  readonly end: number;
  /** HealthKit's value for the whole series: its total, or its (time-weighted) average. */
  readonly value: number | null;
  readonly source: string;
  /** Null when they weren't uploaded. */
  readonly values: QuantitySeriesValues | null;
  /** A discrete series' lowest and highest values. */
  readonly minimum: number | null;
  readonly maximum: number | null;
}

/**
 * A series' readings: one per value, in order, of those that start by the sample's end and less
 * than `seriesLookbackMillis` after its start; or, without its values, one for the sample, at its
 * start (none without a value either).
 */
export const seriesReadings = (series: QuantitySeriesSample): ReadonlyArray<QuantityReading> => {
  const { values, start, end, source } = series;
  if (values === null) {
    return series.value === null ? [] : [{ start, end, value: series.value, source }];
  }
  const reach = start + seriesLookbackMillis;
  const readings: Array<QuantityReading> = [];
  for (let index = 0; index < values.values.length; index++) {
    const interval = seriesValueInterval(values, index, start);
    if (interval.start <= end && interval.start < reach) {
      readings.push({ ...interval, value: values.values[index]!, source });
    }
  }
  return readings;
};

/**
 * A type's series whose samples start in `[from, to)` and end at or after `endingFrom`, oldest
 * first, then by ID, past tombstones. Through the series' own (type, start_date) index, so a
 * range without series costs a seek.
 */
export const quantitySeries = (
  sql: StoreSql,
  type: string,
  from: number,
  to: number,
  endingFrom: number,
): ReadonlyArray<QuantitySeriesSample> =>
  sql
    .rows(
      `SELECT s.id, s.start_date, s.end_date, s.value, s.source_bundle_id,
        q.times, q.durations, q."values", q.minimum, q.maximum
      FROM health_quantity_series q JOIN health_sample s ON s.id = q.id
      WHERE q.type = ? AND q.start_date >= ? AND q.start_date < ? AND s.end_date >= ?
        AND ${liveSample}
      ORDER BY q.start_date, q.id`,
      type,
      from,
      to,
      endingFrom,
    )
    .map(([id, start, end, value, source, times, durations, values, minimum, maximum]) => ({
      id: id as string,
      start: Number(start),
      end: Number(end),
      value: numberOrNull(value),
      source: source as string,
      values: quantitySeriesValues(times, durations, values),
      minimum: numberOrNull(minimum),
      maximum: numberOrNull(maximum),
    }));

/** A quantity type's readings, oldest first, with a series' values as readings of their own. */
export interface QuantityReadings {
  readonly readings: ReadonlyArray<QuantityReading>;
  /**
   * The lowest and highest value of readings that stand for a series without its values, by
   * index in `readings`: its own minimum and maximum, which minimums and maximums take.
   */
  readonly extremes: ReadonlyMap<number, readonly [number, number]>;
}

/**
 * A quantity type's readings that start in `[from, to)`, oldest first: each sample with a value,
 * except that a series is one reading per value, at the value's own time (`seriesReadings`), of
 * the series that started up to `seriesLookbackMillis` before `from` too. A series without its
 * values stays one reading, at its start, whose extremes are the series'. Readings that start
 * together keep single samples first, by ID, then series by start, ID and value, as the Mac's
 * `HealthDatabase.quantityReadings` orders them.
 */
export const quantityReadings = (
  sql: StoreSql,
  type: string,
  from: number,
  to: number,
): QuantityReadings => {
  const series = quantitySeries(sql, type, from - seriesLookbackMillis, to, from);
  const seriesIds = new Set(series.filter((sample) => sample.start >= from).map(({ id }) => id));
  const singles: Array<QuantityReading> = [];
  for (const [start, end, value, source, id] of samplesStarting(
    sql,
    `start_date, end_date, value, source_bundle_id${seriesIds.size === 0 ? "" : ", id"}`,
    type,
    from,
    to,
    "AND value IS NOT NULL",
  )) {
    if (seriesIds.size !== 0 && seriesIds.has(id as string)) continue;
    singles.push({
      start: Number(start),
      end: Number(end),
      value: Number(value),
      source: source as string,
    });
  }
  if (series.length === 0) return { readings: singles, extremes: new Map() };

  // Every series' readings in range, by start, then the series' order, then their own: a stable
  // sort keeps the last two.
  const values: Array<{ reading: QuantityReading; extremes: readonly [number, number] | null }> =
    [];
  for (const sample of series) {
    const extremes: readonly [number, number] | null =
      sample.values === null && sample.minimum !== null && sample.maximum !== null
        ? [sample.minimum, Math.max(sample.minimum, sample.maximum)]
        : null;
    for (const reading of seriesReadings(sample)) {
      if (reading.start >= from && reading.start < to) values.push({ reading, extremes });
    }
  }
  values.sort((a, b) => a.reading.start - b.reading.start);

  const readings: Array<QuantityReading> = [];
  const extremes = new Map<number, readonly [number, number]>();
  let single = 0;
  for (const { reading, extremes: range } of values) {
    while (single < singles.length && singles[single]!.start <= reading.start) {
      readings.push(singles[single]!);
      single++;
    }
    if (range !== null) extremes.set(readings.length, range);
    readings.push(reading);
  }
  for (; single < singles.length; single++) readings.push(singles[single]!);
  return { readings, extremes };
};

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
 * Up to `limit` of a type's samples, or a correlation type's correlations (`correlation`), that
 * start in `[from, to)`, newest first (by start, then ID, both descending), after `cursor` (as
 * the Mac's `HealthDatabase.samplePage` and `correlationPage`), with their source revision, device
 * and metadata (851-4166); with `includingCursor`, the cursor's own sample first, whose series'
 * values a page of them ended inside (851-4171). Correlations have no value, and no tombstones (they have no key
 * fields, so they're deleted at once).
 */
export const samplePage = (
  sql: StoreSql,
  type: string,
  range: { readonly from: number; readonly to: number },
  cursor: SampleCursor | null,
  limit: number,
  correlation = false,
  includingCursor = false,
): ReadonlyArray<DetailedSampleRow> =>
  sql
    .exec(
      `SELECT s.id, s.start_date, s.end_date,
        ${correlation ? "NULL AS value, NULL AS unit, NULL AS category_value" : "s.value, s.unit, s.category_value"},
        s.source_name, s.source_bundle_id,
        coalesce(s.source_revision, p.source_revision) AS source_revision,
        coalesce(s.device, p.device) AS device, s.metadata
      FROM ${correlation ? "health_correlation" : "health_sample"} s
      LEFT JOIN health_provenance p ON p.id = s.provenance
      WHERE s.type = ? AND s.start_date >= ? AND s.start_date < ?
        ${cursor === null ? "" : `AND s.start_date <= ? AND (s.start_date < ? OR s.id ${includingCursor ? "<=" : "<"} ?)`}
        ${correlation ? "" : `AND ${liveSample}`}
      ORDER BY s.start_date DESC, s.id DESC LIMIT ?`,
      type,
      range.from,
      range.to,
      ...(cursor === null ? [] : [cursor.startDate, cursor.startDate, cursor.id]),
      limit,
    )
    .map(detailedRow);

/** A quantity series' row (851-4149), as `samples` shows it. */
export interface QuantitySeriesRow {
  readonly count: number;
  readonly values: QuantitySeriesValues | null;
  readonly minimum: number | null;
  readonly maximum: number | null;
  readonly mostRecent: number | null;
  readonly mostRecentStartDate: number | null;
  readonly mostRecentEndDate: number | null;
}

/**
 * The quantity series of `samples` that are series, by ID, with their values only `withValues`
 * (a page of summaries needn't parse hundreds of arrays). The IDs go in as one JSON array, since
 * a Durable Object's SQLite binds at most 100 parameters.
 */
export const quantitySeriesOf = (
  sql: StoreSql,
  samples: ReadonlyArray<string>,
  withValues: boolean,
): ReadonlyMap<string, QuantitySeriesRow> =>
  samples.length === 0
    ? new Map()
    : new Map(
        sql
          .exec(
            `SELECT id, count, ${withValues ? `times, durations, "values",` : ""} minimum, maximum,
              most_recent, most_recent_start_date, most_recent_end_date
            FROM health_quantity_series WHERE id IN (SELECT value FROM json_each(?))`,
            JSON.stringify(samples),
          )
          .map((row) => [
            row["id"] as string,
            {
              count: Number(row["count"]),
              values: withValues
                ? quantitySeriesValues(row["times"], row["durations"], row["values"])
                : null,
              minimum: numberOrNull(row["minimum"]),
              maximum: numberOrNull(row["maximum"]),
              mostRecent: numberOrNull(row["most_recent"]),
              mostRecentStartDate: numberOrNull(row["most_recent_start_date"]),
              mostRecentEndDate: numberOrNull(row["most_recent_end_date"]),
            },
          ]),
      );

/** A correlation's member sample: its type, value and unit. */
export interface CorrelatedValueRow {
  readonly correlationId: string;
  readonly type: string;
  readonly value: number | null;
  readonly unit: string | null;
}

/**
 * The samples in each of `correlations`, past tombstones, by correlation, then systolic before
 * diastolic (blood pressure reads 118/76), then by type and ID. Only correlation pages read them,
 * a page's IDs at once, through the `correlation_id` index. The Mac's `correlatedSamples` orders
 * them alike.
 */
export const correlatedValues = (
  sql: StoreSql,
  correlations: ReadonlyArray<string>,
): ReadonlyArray<CorrelatedValueRow> =>
  correlations.length === 0
    ? []
    : sql
        .exec(
          `SELECT s.correlation_id, s.type, s.value, s.unit FROM health_sample s
          WHERE s.correlation_id IN (SELECT value FROM json_each(?)) AND ${liveSample}
          ORDER BY s.correlation_id, s.type <> 'HKQuantityTypeIdentifierBloodPressureSystolic',
            s.type, s.id`,
          JSON.stringify(correlations),
        )
        .map((row) => ({
          correlationId: row["correlation_id"] as string,
          type: row["type"] as string,
          value: numberOrNull(row["value"]),
          unit: stringOrNull(row["unit"]),
        }));

export interface WorkoutRow {
  readonly id: string;
  readonly activityType: number;
  readonly startDate: number;
  readonly endDate: number;
  readonly duration: number;
  /** As stored: JSON. */
  readonly statistics: string;
  /** As stored: JSON. */
  readonly activities: string;
  /** As stored: JSON, or null. */
  readonly metadata: string | null;
  readonly sourceName: string;
}

/** The columns `workoutRow` reads; `workout` adds `events`, which `workouts` doesn't need. */
const workoutColumns = `id, activity_type, start_date, end_date, duration, statistics, activities,
  metadata, source_name`;

const workoutRow = (row: Record<string, unknown>): WorkoutRow => ({
  id: row["id"] as string,
  activityType: Number(row["activity_type"]),
  startDate: Number(row["start_date"]),
  endDate: Number(row["end_date"]),
  duration: Number(row["duration"]),
  statistics: row["statistics"] as string,
  activities: row["activities"] as string,
  metadata: row["metadata"] as string | null,
  sourceName: row["source_name"] as string,
});

/** Up to `limit` of the workouts that start in `[from, to)`, newest first. */
export const workoutsStarting = (
  sql: StoreSql,
  from: number,
  to: number,
  limit: number,
): ReadonlyArray<WorkoutRow> =>
  sql
    .exec(
      `SELECT ${workoutColumns} FROM health_workout WHERE start_date >= ? AND start_date < ?
      ORDER BY start_date DESC, id DESC LIMIT ?`,
      from,
      to,
      limit,
    )
    .map(workoutRow);

/** A workout as `workout` reads it: its row, with its events. */
export interface WorkoutDetailRow extends WorkoutRow {
  /** As stored: JSON. */
  readonly events: string;
}

/** The workout with HealthKit's UUID `id`, if there's one. */
export const workoutWithId = (sql: StoreSql, id: string): WorkoutDetailRow | undefined =>
  sql
    .exec(`SELECT ${workoutColumns}, events FROM health_workout WHERE id = ?`, id)
    .map((row) => ({ ...workoutRow(row), events: row["events"] as string }))[0];

/**
 * The IDs of those of `workouts` that have a route with locations, as the Mac's workout page
 * finds a workout's route (`HealthDatabase.route(of:)`): one HealthKit linked to it, or else one
 * linked to no workout that was recorded during it. One read of the routes for all of them,
 * rather than a search of the routes for each.
 */
export const workoutsWithRoutes = (
  sql: StoreSql,
  workouts: ReadonlyArray<WorkoutRow>,
): ReadonlySet<string> => {
  if (workouts.length === 0) return new Set();
  const from = Math.min(...workouts.map((workout) => workout.startDate));
  const to = Math.max(...workouts.map((workout) => workout.endDate));
  const routes = sql
    .exec(
      `SELECT workout, start_date, end_date FROM health_workout_route
      WHERE locations IS NOT NULL AND (workout IN (SELECT value FROM json_each(?))
        OR (workout IS NULL AND start_date < ? AND end_date > ?))`,
      JSON.stringify(workouts.map((workout) => workout.id)),
      to,
      from,
    )
    .map((row) => ({
      workout: row["workout"] as string | null,
      startDate: Number(row["start_date"]),
      endDate: Number(row["end_date"]),
    }));
  return new Set(
    workouts
      .filter((workout) =>
        routes.some((route) =>
          route.workout === null
            ? route.startDate < workout.endDate && route.endDate > workout.startDate
            : route.workout === workout.id,
        ),
      )
      .map((workout) => workout.id),
  );
};

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
