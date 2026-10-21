import type { SqlValue, StoreSql } from "../../store/StoreSql.ts";

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

/**
 * How many workouts started in `[from, to)` and by `now` (a workout an app dated later today
 * hasn't happened), and their total duration in seconds.
 */
export const workoutTotals = (sql: StoreSql, from: number, to: number, now: number) => {
  const row = sql.exec(
    `SELECT count(*) AS count, total(duration) AS duration FROM health_workout
    WHERE start_date >= ? AND start_date < ? AND start_date <= ?`,
    from,
    to,
    now,
  )[0];
  return { count: Number(row?.["count"] ?? 0), duration: Number(row?.["duration"] ?? 0) };
};

/** The types pinned to Summary, in order (as the Mac's `HealthDatabase.summaryPins`). */
export const summaryPins = (sql: StoreSql): ReadonlyArray<string> =>
  sql.exec("SELECT id FROM health_pin ORDER BY position, id").map((row) => row["id"] as string);
