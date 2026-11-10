import { seriesLookbackMillis } from "../tools/HealthQueries.ts";
import type { CardReading } from "./CardEngine.ts";

// Quantity series' values as readings (851-4172, `docs/decisions/cards.md` › Readings and weights):
// the Swift core's `CardSeries`. A quantity sample whose `count` is over 1 is a series, its value
// HealthKit's for the whole series; every engine reads a series as its values, one reading each,
// with the sample's source and ID. The server reads them from `health_quantity_series`. A series
// uploaded without its values stays one reading.

/**
 * How long after its start (in milliseconds) a series' values count: a week, the tools'
 * `seriesLookbackMillis` (851-4171), as the Swift core's `CardSeries.reach`. A range reads the
 * series that started this long before it too; values later than that, or after the sample's end,
 * count nowhere.
 */
export const cardSeriesReach = seriesLookbackMillis;

interface Range {
  readonly start: number;
  readonly end: number;
}

/** The starts of the series whose values can start in `range`. */
export const cardSeriesStarts = (range: Range): Range => ({
  start: range.start - cardSeriesReach,
  end: range.end,
});

/**
 * One series: its sample, as a reading, and its values, in order; null when it was uploaded
 * without them, or they don't line up: then it's read as its sample.
 */
export interface CardSeries {
  readonly sample: CardReading;
  readonly values: ReadonlyArray<CardReading> | null;
}

/** Whether a value starting at `start` counts: by the sample's end, and less than the reach after its start. */
const counts = (start: number, sample: CardReading) =>
  start <= sample.end && start < sample.start + cardSeriesReach;

/** A time or duration the tools take: from 0 to 1e9 s (about 31 years). */
const isSeconds = (seconds: unknown) =>
  typeof seconds === "number" && seconds >= 0 && seconds <= 1e9;

/**
 * A series from `health_quantity_series`' arrays: each value's start and duration in seconds since
 * the series' `start` (Unix milliseconds), to the millisecond, and the value in the type's catalog
 * unit. Its values are null when there are none, the arrays don't have one number each, or a time
 * or duration isn't from 0 to 1e9 s, as the tools read them. Only those that count are kept.
 */
export const cardSeries = (
  sample: CardReading,
  start: number,
  times: ReadonlyArray<unknown>,
  durations: ReadonlyArray<unknown>,
  values: ReadonlyArray<unknown>,
): CardSeries => {
  if (times.length === 0 || durations.length !== times.length || values.length !== times.length) {
    return { sample, values: null };
  }
  const readings: Array<CardReading> = [];
  for (let index = 0; index < times.length; index++) {
    const time = times[index];
    const duration = durations[index];
    const value = values[index];
    if (!isSeconds(time) || !isSeconds(duration) || typeof value !== "number") {
      return { sample, values: null };
    }
    const valueStart = start + Math.round((time as number) * 1000);
    if (!counts(valueStart, sample)) continue;
    readings.push({
      start: valueStart,
      end: valueStart + Math.round((duration as number) * 1000),
      value,
      source: sample.source,
      sampleId: sample.sampleId,
    });
  }
  return { sample, values: readings };
};

/** The first index whose element is true for `test`, in an array partitioned by it. */
const partitioningIndex = <T>(
  array: ReadonlyArray<T>,
  test: (element: T) => boolean,
  from = 0,
): number => {
  let low = from;
  let high = array.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (test(array[middle]!)) high = middle;
    else low = middle + 1;
  }
  return low;
};

/** A series' readings starting in `range`: its values', or its sample's without them. */
export const seriesReadings = (series: CardSeries, range: Range): ReadonlyArray<CardReading> => {
  const { values, sample } = series;
  if (values === null) {
    return sample.start >= range.start && sample.start < range.end ? [sample] : [];
  }
  // Values are in order: a slice.
  const lower = partitioningIndex(values, (value) => value.start >= range.start);
  const upper = partitioningIndex(values, (value) => value.start >= range.end, lower);
  return values.slice(lower, upper);
};

/** The readings in `range` of `series` (by start): each series' that has any, in their order. */
export const readingsOfSeries = (
  series: ReadonlyArray<CardSeries>,
  range: Range,
): Array<ReadonlyArray<CardReading>> => {
  const from = cardSeriesStarts(range).start;
  const readings: Array<ReadonlyArray<CardReading>> = [];
  for (
    let index = partitioningIndex(series, ({ sample }) => sample.start >= from);
    index < series.length && series[index]!.sample.start < range.end;
    index++
  ) {
    const inRange = seriesReadings(series[index]!, range);
    if (inRange.length > 0) readings.push(inRange);
  }
  return readings;
};

/**
 * Whether one of `series` (by start) starts in `range`: then the samples in it are read leaving
 * series out, which are read as their values.
 */
export const anySeriesStarts = (range: Range, series: ReadonlyArray<CardSeries>): boolean => {
  const first = partitioningIndex(series, ({ sample }) => sample.start >= range.start);
  return first < series.length && series[first]!.sample.start < range.end;
};

/**
 * Readings of single samples (oldest first, as fetched) with series' readings (each series' in
 * order, the series by start), oldest first: by start, a single sample before a series' value
 * starting in the same millisecond, and series' values starting together in their series' order.
 */
export const mergedReadings = (
  singles: Array<CardReading>,
  series: ReadonlyArray<ReadonlyArray<CardReading>>,
): Array<CardReading> => {
  const values: Array<CardReading> = [];
  let inOrder = true;
  for (const readings of series) {
    if (values.length > 0 && readings.length > 0 && readings[0]!.start < values.at(-1)!.start) {
      inOrder = false;
    }
    for (const reading of readings) values.push(reading);
  }
  // Series overlap (two sources', or one's), so their values interleave. `Array.prototype.sort`
  // is stable, so values starting together keep the series' order.
  if (!inOrder) values.sort((a, b) => a.start - b.start);
  if (values.length === 0) return singles;
  if (singles.length === 0) return values;
  const merged: Array<CardReading> = [];
  let single = 0;
  let value = 0;
  while (single < singles.length && value < values.length) {
    if (values[value]!.start < singles[single]!.start) {
      merged.push(values[value++]!);
    } else {
      merged.push(singles[single++]!);
    }
  }
  while (single < singles.length) merged.push(singles[single++]!);
  while (value < values.length) merged.push(values[value++]!);
  return merged;
};

/**
 * The latest reading started by `now` of a type whose latest sample started by then is `sample`,
 * for a Summary row's headline: the sample, or a series' value starting after it, or the sample's
 * own latest value when it's a series (`sampleIsSeries`). `values`: the readings starting from the
 * sample's start to `now` of the series that can have them.
 */
export const latestSeriesReading = (
  sample: CardReading,
  sampleIsSeries: boolean,
  values: ReadonlyArray<CardReading>,
): CardReading => {
  let latest: CardReading | null = sampleIsSeries ? null : sample;
  for (const value of values) {
    if (latest === null || value.start > latest.start) latest = value;
  }
  // A series whose values all start after `now`: its sample's value.
  return latest ?? sample;
};
