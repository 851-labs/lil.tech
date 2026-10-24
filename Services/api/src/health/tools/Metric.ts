import { Clock, type DateTime, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import type { HealthAggregation } from "../HealthCatalog.ts";
import { cumulativeTotalsBy, sampleReadings } from "./HealthQueries.ts";
import { HealthToolError, type HealthToolkit } from "./HealthToolkit.ts";
import {
  bucketIndex,
  dayStarts,
  hourMillis,
  localTime,
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

/** The longest a sample counts for in a time-weighted average. */
const maxSampleWeightMillis = hourMillis;

/**
 * A cumulative type's totals per hour or day in the period (by when they start, in `zone`), as the
 * Mac's `HealthDatabase.cumulativeTotals` (`cumulativeTotalsBy` in `HealthQueries.ts`). A D range's
 * hours are a day of rows at most; days are worked out once a day, as rows come in order
 * (851-2906).
 */
const periodTotals = (
  sql: StoreSql,
  type: string,
  period: ToolPeriod,
  by: "hour" | "day",
  now: number,
  zone: DateTime.TimeZone,
) =>
  cumulativeTotalsBy(
    sql,
    type,
    period,
    by === "hour" ? (millis: number) => startOfHour(millis, zone) : dayStarts(zone),
    now,
  );

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

/** A reading of a discrete type: a sample with a value, and its source's bundle ID. */
interface Reading {
  readonly start: number;
  readonly end: number;
  readonly value: number;
  readonly source: string;
}

/** One statistic's running totals, added to a reading at a time, in order. */
class Accumulator {
  readonly aggregation: HealthAggregation;
  count = 0;
  least = Infinity;
  most = -Infinity;
  totalWeight = 0;
  weighted = 0;

  // Not a parameter property, which Node's type stripping can't run.
  constructor(aggregation: HealthAggregation) {
    this.aggregation = aggregation;
  }

  add(value: number, weight: number) {
    this.count++;
    this.least = Math.min(this.least, value);
    this.most = Math.max(this.most, value);
    this.totalWeight += weight;
    this.weighted +=
      this.aggregation === "discreteEquivalentContinuousLevel"
        ? weight * 10 ** (value / 10)
        : value * weight;
  }

  /** The statistic, or null without any readings. */
  result(statistic: Exclude<Statistic, "sum">): number | null {
    if (this.count === 0) return null;
    if (statistic === "minimum") return this.least;
    if (statistic === "maximum") return this.most;
    if (this.totalWeight <= 0) return 0;
    if (this.aggregation === "discreteEquivalentContinuousLevel") {
      return 10 * Math.log10(this.weighted / this.totalWeight);
    }
    return this.weighted / this.totalWeight;
  }
}

/**
 * A discrete type's statistic over the period and each of its buckets, from the readings that
 * start in them (`readings` by start, reaching an hour past the period's end), weighted by the
 * type's aggregation style, as the Mac's `HealthDatabase.discreteStatistic` weighs each bucket on
 * its own:
 * - Time-weighted: each counts until its source's next reading, up to an hour, and a source's
 *   last one for its own duration. Sources are weighted separately, so a second device's readings
 *   don't cut the first's short. The Mac reads a bucket's readings up to an hour past its end, so
 *   a reading counts until its source's next one only if that starts by then.
 * - Equivalent continuous level (sound): by duration.
 * - Arithmetic: all the same.
 * At least a second each. In one pass over the readings, adding each to its bucket's totals and
 * the period's in the Mac's order, so the sums come out the same (851-2906).
 */
const discreteStatistics = (
  readings: ReadonlyArray<Reading>,
  period: ToolPeriod,
  aggregation: HealthAggregation,
  statistic: Exclude<Statistic, "sum">,
): { readonly value: number | null; readonly buckets: ReadonlyArray<number | null> } => {
  const timeWeighted = aggregation === "discreteTemporallyWeighted";
  // When each reading's source has its next one (NaN for its last), for time-weighted types.
  const nextStarts = new Float64Array(timeWeighted ? readings.length : 0);
  if (timeWeighted) {
    const nextStart = new Map<string, number>();
    for (let index = readings.length - 1; index >= 0; index--) {
      const reading = readings[index]!;
      nextStarts[index] = nextStart.get(reading.source) ?? Number.NaN;
      nextStart.set(reading.source, reading.start);
    }
  }
  /** A reading's weight among the readings read up to `reach`. */
  const weight = (index: number, reach: number) => {
    const reading = readings[index]!;
    if (timeWeighted) {
      const next = nextStarts[index]!;
      const until = next < reach ? next : reading.end;
      return Math.min(Math.max((until - reading.start) / 1000, 1), maxSampleWeightMillis / 1000);
    }
    if (aggregation === "discreteEquivalentContinuousLevel") {
      return Math.max((reading.end - reading.start) / 1000, 1);
    }
    return 1;
  };
  const reach = (end: number) => (timeWeighted ? end + maxSampleWeightMillis : end);
  const whole = new Accumulator(aggregation);
  const wholeReach = reach(period.end);
  const buckets = period.buckets.map(() => new Accumulator(aggregation));
  let bucket = 0;
  let bucketReach = reach(period.buckets[1] ?? period.end);
  for (let index = 0; index < readings.length; index++) {
    const reading = readings[index]!;
    if (reading.start < period.start) continue;
    if (reading.start >= period.end) break;
    while (bucket + 1 < period.buckets.length && reading.start >= period.buckets[bucket + 1]!) {
      bucket++;
      bucketReach = reach(period.buckets[bucket + 1] ?? period.end);
    }
    const bucketWeight = weight(index, bucketReach);
    buckets[bucket]!.add(reading.value, bucketWeight);
    // Only a time-weighted reading's weight depends on how far the readings reach.
    whole.add(
      reading.value,
      timeWeighted && bucketReach !== wholeReach ? weight(index, wholeReach) : bucketWeight,
    );
  }
  return {
    value: whole.result(statistic),
    buckets: buckets.map((totals) => totals.result(statistic)),
  };
};

/**
 * The `metric` tool from the user's store: a quantity type's statistic over the period, overall
 * and per bucket.
 * - Types that add up (steps): totals come from the statistics source's buckets, and the samples'
 *   own past them. `sum` is the total (the default); `average`, `minimum` and `maximum` are of the
 *   days' totals (days with data), as Metric Detail's header average (AVERAGE for W and M, DAILY
 *   AVERAGE for 6M and Y), or of a D range's hours' totals.
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
    const totals = periodTotals(
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
    // An hour past the end, for time-weighted readings near it.
    const readings = sampleReadings(sql, type.id, period.start, period.end + maxSampleWeightMillis);
    ({ value, buckets } = discreteStatistics(readings, period, aggregation, statistic));
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
