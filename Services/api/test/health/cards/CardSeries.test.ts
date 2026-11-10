import { assert, describe, it } from "@effect/vitest";
import type { CardReading } from "../../../src/health/cards/CardEngine.ts";
import {
  type CardSeries,
  anySeriesStarts,
  cardSeries,
  cardSeriesReach,
  cardSeriesStarts,
  latestSeriesReading,
  mergedReadings,
  readingsOfSeries,
  seriesReadings,
} from "../../../src/health/cards/CardSeries.ts";

// Quantity series' values as readings in the server engine's core (851-4172), the Swift core's
// `CardSeriesTests` ported case for case.

const watch = "com.apple.health.watch";
const strap = "org.example.strap";

const reading = (
  start: number,
  value: number,
  { end = start, source = watch, id = "" }: { end?: number; source?: string; id?: string } = {},
): CardReading => ({ start, end, value, source, sampleId: id });

const series = (
  id: string,
  start: number,
  times: ReadonlyArray<unknown>,
  values: ReadonlyArray<unknown>,
  durations?: ReadonlyArray<unknown>,
): CardSeries =>
  cardSeries(
    // The sample ends with its last value, as HealthKit's do.
    reading(start, 0, {
      id,
      end:
        start + Math.round(Math.max(0, ...times.filter((time) => typeof time === "number")) * 1000),
    }),
    start,
    times,
    durations ?? times.map(() => 0),
    values,
  );

describe("CardSeries", () => {
  it("reads the values starting in the range", () => {
    const a = series("a", 1_000_000, [0, 0.5, 1.234, 2], [60, 61, 62, 63], [0, 0.25, 0, 0]);
    assert.deepStrictEqual(seriesReadings(a, { start: 1_000_500, end: 1_002_000 }), [
      reading(1_000_500, 61, { end: 1_000_750, id: "a" }),
      reading(1_001_234, 62, { id: "a" }),
    ]);
    assert.deepStrictEqual(seriesReadings(a, { start: 0, end: 1 }), []);
  });

  it("counts values by the sample's end and within a week, as the tools read them", () => {
    const week = cardSeriesReach / 1000;
    const long = series("a", 0, [0, week - 1, week], [1, 2, 3]);
    assert.deepStrictEqual(
      long.values?.map(({ value }) => value),
      [1, 2],
    );
    const past = cardSeries(reading(0, 0, { end: 1000 }), 0, [0, 1, 2], [0, 0, 0], [1, 2, 3]);
    assert.deepStrictEqual(
      past.values?.map(({ value }) => value),
      [1, 2],
    );
    assert.isNull(series("a", 0, [0, -1], [1, 2]).values);
    assert.isNull(series("a", 0, [0, 2e9], [1, 2]).values);
  });

  it("reads a series without values as its sample", () => {
    // Arrays of something other than numbers too, which the Mac can't parse either.
    for (const broken of [
      series("a", 0, [0, 1], [60]),
      series("a", 0, [], []),
      series("a", 0, [0], ["60"]),
    ]) {
      assert.isNull(broken.values);
      assert.deepStrictEqual(seriesReadings(broken, { start: 0, end: 10_000 }), [broken.sample]);
      assert.deepStrictEqual(seriesReadings(broken, { start: 1, end: 10_000 }), []);
    }
  });

  it("reads the series in a range: a week before it or later, and before its end", () => {
    const day = cardSeriesReach;
    const all = [
      series("a", 0, [0, 1], [1, 2]),
      series("b", day, [0, 1], [3, 4]),
      series("c", 2 * day, [0, 1], [5, 6]),
    ];
    assert.deepStrictEqual(
      readingsOfSeries(all, { start: day + 500, end: 2 * day + 1 })
        .flat()
        .map(({ value }) => value),
      [4, 5],
    );
    assert.isTrue(anySeriesStarts({ start: day + 1, end: 2 * day + 1 }, all));
    assert.isFalse(anySeriesStarts({ start: day + 1, end: 2 * day }, all));
    assert.deepStrictEqual(cardSeriesStarts({ start: 1_000_000_000, end: 2_000_000_000 }), {
      start: 395_200_000,
      end: 2_000_000_000,
    });
  });

  it("merges by start", () => {
    const singles = [reading(1000, 1, { source: strap }), reading(3000, 3, { source: strap })];
    const a = [
      reading(1000, 10, { id: "a" }),
      reading(2000, 20, { id: "a" }),
      reading(4000, 40, { id: "a" }),
    ];
    const b = [reading(2000, 21, { id: "b" }), reading(2500, 25, { id: "b" })];
    assert.deepStrictEqual(
      mergedReadings(singles, [a, b]).map(({ value }) => value),
      [1, 10, 20, 21, 25, 3, 40],
    );
    assert.deepStrictEqual(mergedReadings(singles, []), singles);
    assert.deepStrictEqual(mergedReadings([], [a]), a);
    // Series one after another need no sort.
    assert.deepStrictEqual(
      mergedReadings([], [b, a.slice(2)]).map(({ value }) => value),
      [21, 25, 40],
    );
  });

  it("finds the latest reading", () => {
    const sample = reading(1000, 75, { source: strap, id: "s" });
    const later = [reading(1000, 60, { id: "a" }), reading(1500, 90, { id: "a" })];
    assert.strictEqual(latestSeriesReading(sample, false, later).value, 90);
    // A value starting with the sample doesn't replace it.
    assert.strictEqual(latestSeriesReading(sample, false, [later[0]!]).value, 75);
    // The sample is the series: its latest value by now.
    assert.strictEqual(latestSeriesReading(later[0]!, true, later).value, 90);
    // A series without values by now: its sample.
    assert.strictEqual(latestSeriesReading(sample, true, []).value, 75);
  });
});
