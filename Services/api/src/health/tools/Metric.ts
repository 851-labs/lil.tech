import { Clock, type DateTime, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import type { HealthAggregation } from "../HealthCatalog.ts";
import {
  type SampleRow,
  samplesStarting,
  statisticBuckets,
  statisticsDevices,
  statisticsSource,
} from "./HealthQueries.ts";
import { HealthToolError, type HealthToolkit } from "./HealthToolkit.ts";
import {
  bucketIndex,
  localTime,
  startOfDay,
  startOfHour,
  type ToolPeriod,
  type ToolRange,
  toolPeriod,
  toolTimeZone,
} from "./ToolTime.ts";
import { resolveHealthType } from "./ToolTypes.ts";

type MetricResult = (typeof HealthToolkit.tools.metric.successSchema)["Type"];
type Statistic = "sum" | "average" | "minimum" | "maximum";

// `metric`'s statistics as the Mac computes them (`HealthTools.metric`), with the queries of its
// charts, so both MCP servers give the same numbers.

const statisticsBucketMillis = 30 * 60 * 1000;

/** The longest a sample counts for in a time-weighted average. */
const maxSampleWeightMillis = 60 * 60 * 1000;

/** A cumulative type's total over one hour or day. */
interface Total {
  readonly start: number;
  readonly sum: number;
}

/**
 * A cumulative type's totals per hour or day in the period (by when they start, in `zone`), from
 * the statistics source's 30-minute buckets and, past the last of them (no statistics at all, or
 * samples synced before their buckets), the samples' own values, oldest first, as the Mac's
 * `HealthDatabase.cumulativeTotals`. Hours or days without data are left out, and so are empty
 * buckets.
 */
const cumulativeTotals = (
  sql: StoreSql,
  type: string,
  period: ToolPeriod,
  by: "hour" | "day",
  now: number,
  zone: DateTime.TimeZone,
): ReadonlyArray<Total> => {
  const startOf = (millis: number) =>
    by === "hour" ? startOfHour(millis, zone) : startOfDay(millis, zone);
  const source = statisticsSource(statisticsDevices(sql), now);
  const buckets =
    source === null ? [] : statisticBuckets(sql, source, type, period.start, period.end);
  const sums = new Map<number, number>();
  const add = (millis: number, value: number) => {
    const start = startOf(millis);
    sums.set(start, (sums.get(start) ?? 0) + value);
  };
  for (const { bucketStart, sum } of buckets) add(bucketStart, sum);
  // Empty buckets don't count as covered: samples that arrived before their sums still show.
  const lastBucket = buckets.at(-1);
  const covered =
    lastBucket === undefined ? period.start : lastBucket.bucketStart + statisticsBucketMillis;
  for (const sample of samplesStarting(sql, type, covered, period.end)) {
    add(sample.startDate, sample.value ?? 0);
  }
  return [...sums.entries()]
    .map(([start, sum]) => ({ start, sum }))
    .sort((a, b) => a.start - b.start);
};

// Not `Math.min(...values)`, which runs out of stack for a year of heart rate.
const minimum = (values: ReadonlyArray<number>) =>
  values.reduce((least, value) => Math.min(least, value), Infinity);
const maximum = (values: ReadonlyArray<number>) =>
  values.reduce((most, value) => Math.max(most, value), -Infinity);

/** A statistic of totals: their sum, average, minimum or maximum. Null without any. */
const combine = (values: ReadonlyArray<number>, statistic: Statistic): number | null => {
  if (values.length === 0) return null;
  switch (statistic) {
    case "sum":
      return values.reduce((total, value) => total + value, 0);
    case "average":
      return values.reduce((total, value) => total + value, 0) / values.length;
    case "minimum":
      return minimum(values);
    case "maximum":
      return maximum(values);
  }
};

/** A reading of a discrete type: a sample with a value. */
interface Reading {
  readonly start: number;
  readonly end: number;
  readonly value: number;
  readonly source: string;
}

/**
 * Each reading's weight in an average, in seconds (`readings` by start), as the Mac's
 * `HealthDatabase.discreteStatistics`:
 * - Time-weighted: each counts until its source's next reading, up to an hour, and a source's
 *   last one for its own duration. Sources are weighted separately, so a second device's readings
 *   don't cut the first's short.
 * - Equivalent continuous level (sound): by duration.
 * - Arithmetic: all the same.
 * At least a second each.
 */
const weights = (readings: ReadonlyArray<Reading>, aggregation: HealthAggregation) => {
  switch (aggregation) {
    case "discreteTemporallyWeighted": {
      const result = readings.map(() => 1);
      const nextStart = new Map<string, number>();
      for (let index = readings.length - 1; index >= 0; index--) {
        const reading = readings[index]!;
        const until = nextStart.get(reading.source) ?? reading.end;
        result[index] = Math.min(
          Math.max((until - reading.start) / 1000, 1),
          maxSampleWeightMillis / 1000,
        );
        nextStart.set(reading.source, reading.start);
      }
      return result;
    }
    case "discreteEquivalentContinuousLevel":
      return readings.map((reading) => Math.max((reading.end - reading.start) / 1000, 1));
    default:
      return readings.map(() => 1);
  }
};

/**
 * A discrete type's statistic over `[from, to)`, from the readings that start in it, weighted by
 * the type's aggregation style, or null without any. `readings` are sorted by start and reach
 * an hour past `to`, so a time-weighted reading near the end is weighted by its source's next one,
 * as the Mac weighs each bucket on its own.
 */
const discreteStatistic = (
  readings: ReadonlyArray<Reading>,
  from: number,
  to: number,
  aggregation: HealthAggregation,
  statistic: Exclude<Statistic, "sum">,
): number | null => {
  const reach = aggregation === "discreteTemporallyWeighted" ? to + maxSampleWeightMillis : to;
  const window = readings.slice(firstStarting(readings, from), firstStarting(readings, reach));
  const weighted = weights(window, aggregation);
  const values: Array<number> = [];
  const valueWeights: Array<number> = [];
  window.forEach((reading, index) => {
    if (reading.start >= to) return;
    values.push(reading.value);
    valueWeights.push(weighted[index]!);
  });
  if (values.length === 0) return null;
  if (statistic === "minimum") return minimum(values);
  if (statistic === "maximum") return maximum(values);
  const total = valueWeights.reduce((sum, weight) => sum + weight, 0);
  if (total <= 0) return 0;
  if (aggregation === "discreteEquivalentContinuousLevel") {
    const energy = values.reduce(
      (sum, value, index) => sum + valueWeights[index]! * 10 ** (value / 10),
      0,
    );
    return 10 * Math.log10(energy / total);
  }
  return values.reduce((sum, value, index) => sum + value * valueWeights[index]!, 0) / total;
};

/** The index of the first of `readings` (by start) that starts at `millis` or later. */
const firstStarting = (readings: ReadonlyArray<Reading>, millis: number) => {
  let low = 0;
  let high = readings.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (readings[middle]!.start < millis) low = middle + 1;
    else high = middle;
  }
  return low;
};

const reading = (sample: SampleRow): ReadonlyArray<Reading> =>
  sample.value === null
    ? []
    : [
        {
          start: sample.startDate,
          end: sample.endDate,
          value: sample.value,
          source: sample.sourceBundleId,
        },
      ];

/**
 * The `metric` tool from the user's store: a quantity type's statistic over the period, overall
 * and per bucket.
 * - Types that add up (steps): totals come from the statistics source's buckets, and the samples'
 *   own past them. `sum` is the total (the default); `average`, `minimum` and `maximum` are of the
 *   days' totals (days with data), as Health's Daily Average, or of a D range's hours' totals.
 * - Other types (heart rate): from the samples, weighted by the type's aggregation style. They
 *   don't add up, so `sum` is an error.
 */
export const healthMetric = Effect.fn("healthMetric")(function* (
  sql: StoreSql,
  input: {
    readonly type: string;
    readonly range: ToolRange;
    readonly statistic?: Statistic | undefined;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const type = yield* resolveHealthType(input.type);
  const aggregation = type.aggregation;
  if (type.kind !== "quantity" || aggregation === null) {
    return yield* new HealthToolError({
      message:
        `${type.name} (${type.id}) isn't a quantity type, so it has no statistics. Use samples, ` +
        "or the tool for its kind (sleep, workouts, medications).",
    });
  }
  const now = yield* Clock.currentTimeMillis;
  const period = toolPeriod(input.range, input.date, now, zone);
  const cumulative = aggregation === "cumulative";
  const statistic = input.statistic ?? (cumulative ? "sum" : "average");
  let buckets: ReadonlyArray<number | null>;
  let value: number | null;
  if (cumulative) {
    // Days' totals, or a D range's hours'.
    const totals = cumulativeTotals(
      sql,
      type.id,
      period,
      period.range === "D" ? "hour" : "day",
      now,
      zone,
    );
    const grouped = period.buckets.map((): Array<number> => []);
    for (const total of totals) {
      const index = bucketIndex(period, total.start);
      if (index !== undefined) grouped[index]!.push(total.sum);
    }
    buckets = grouped.map((sums) => combine(sums, statistic));
    value = combine(
      totals.map((total) => total.sum),
      statistic,
    );
  } else {
    if (statistic === "sum") {
      return yield* new HealthToolError({
        message: `${type.name} doesn't add up, so it has no sum. Use average, minimum or maximum.`,
      });
    }
    const readings = samplesStarting(
      sql,
      type.id,
      period.start,
      period.end + maxSampleWeightMillis,
    ).flatMap(reading);
    buckets = period.buckets.map((start, index) =>
      discreteStatistic(
        readings,
        start,
        period.buckets[index + 1] ?? period.end,
        aggregation,
        statistic,
      ),
    );
    value = discreteStatistic(readings, period.start, period.end, aggregation, statistic);
  }
  const result: MetricResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    type: type.id,
    unit: type.unit,
    statistic,
    value,
    buckets: period.buckets.map((start, index) => ({
      start: localTime(start, zone),
      value: buckets[index] ?? null,
    })),
  };
  return result;
});
