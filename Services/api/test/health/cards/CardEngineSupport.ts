import { DateTime, Option, Schema } from "effect";
import type { CardCalendar } from "../../../src/health/cards/CardCalendar.ts";
import { addGrains, grainStart } from "../../../src/health/cards/CardCalendar.ts";
import {
  type CardFetchResult,
  type CardReading,
  CardRun,
  type CardRunData,
  type CardTotal,
  type CardWorkout,
} from "../../../src/health/cards/CardEngine.ts";
import type { CardSleepRecord } from "../../../src/health/cards/CardNights.ts";
import { CardSpec, type CardRange } from "../../../src/health/cards/CardSpec.ts";
import { canonicalCardSpec } from "../../../src/health/cards/CardSpecValidator.ts";

// What the engine's tests share, as the Swift core's `CardEngineSupport` does: synthetic readings,
// sleep and workouts, in London with weeks from Monday, and an in-memory engine. Synthetic data
// only (AGENTS.md).

export const heartRate = "HKQuantityTypeIdentifierHeartRate";
export const restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate";
export const bodyMass = "HKQuantityTypeIdentifierBodyMass";
export const steps = "HKQuantityTypeIdentifierStepCount";
export const bodyTemperature = "HKQuantityTypeIdentifierBodyTemperature";
export const hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN";

/** London, weeks from Monday: a time zone with daylight saving. */
export const london: CardCalendar = {
  zone: Option.getOrThrow(DateTime.zoneMakeNamed("Europe/London")),
  timeZone: "Europe/London",
  firstWeekday: "monday",
};

export const minute = 60_000;
export const hour = 60 * minute;

/** A moment on London's clock, in Unix milliseconds (2026 unless `year` says otherwise). */
export const date = (month: number, day: number, hours = 0, minutes = 0, year = 2026): number =>
  DateTime.toEpochMillis(
    DateTime.makeZonedUnsafe(
      { year, month, day, hour: hours, minute: minutes },
      { timeZone: london.zone, adjustForTimeZone: true },
    ),
  );

/** The day `days` after the one starting at `start`, on London's calendar. */
export const addDays = (start: number, days: number) => addGrains(london, "day", start, days);

export const reading = (
  start: number,
  value: number,
  options: { readonly minutes?: number; readonly source?: string; readonly id?: string } = {},
): CardReading => ({
  start,
  end: start + (options.minutes ?? 1) * minute,
  value,
  source: options.source ?? "com.example",
  sampleId: options.id ?? "",
});

/** A spec from input JSON, canonicalized as apps and tools do. */
export const spec = (input: unknown): CardSpec => {
  const result = canonicalCardSpec(input as never);
  if (result.errors !== undefined) throw new Error(JSON.stringify(result.errors));
  return Schema.decodeUnknownSync(CardSpec)(result.spec);
};

export interface Data {
  readonly readings?: Readonly<Record<string, ReadonlyArray<CardReading>>>;
  readonly hourlyTotals?: Readonly<Record<string, ReadonlyArray<CardTotal>>>;
  readonly sleep?: ReadonlyArray<CardSleepRecord>;
  readonly workouts?: ReadonlyArray<CardWorkout>;
}

/** The run with its windows, from the records and workouts each window fetch's range overlaps. */
export const windowed = (run: CardRun, data: Data): CardRun =>
  run.windowed(
    run.windowFetches.map((fetch) =>
      fetch._tag === "sleep"
        ? {
            _tag: "sleep",
            records: (data.sleep ?? [])
              .filter((record) => record.start < fetch.range.end && record.end > fetch.range.start)
              .sort((a, b) => a.start - b.start),
          }
        : {
            _tag: "workouts",
            workouts: (data.workouts ?? []).filter(
              (workout) => workout.start < fetch.range.end && workout.end > fetch.range.start,
            ),
          },
    ),
  );

/**
 * What each fetch asks for, from in-memory data: readings by type, and cumulative types' hourly
 * totals added up into the fetch's buckets as `cumulativeTotals` does.
 */
export const fetch = (run: CardRun, data: Data): Array<CardFetchResult> =>
  run.fetches.map((item) => {
    const { kind } = item;
    const readings = data.readings?.[item.type] ?? [];
    switch (kind._tag) {
      case "readings":
        return {
          _tag: "readings",
          readings: readings.filter(
            (candidate) => candidate.start >= kind.range.start && candidate.start < kind.range.end,
          ),
        };
      case "stretchReadings":
        return {
          _tag: "readings",
          readings: readings.filter((candidate) =>
            kind.stretches.some(
              (stretch) => stretch.start <= candidate.start && candidate.start < stretch.end,
            ),
          ),
        };
      case "totals": {
        const sums = new Map<number, number>();
        for (const total of data.hourlyTotals?.[item.type] ?? []) {
          if (total.start < kind.range.start || total.start >= kind.range.end) continue;
          const start = grainStart(run.calendar, kind.grain, total.start);
          sums.set(start, (sums.get(start) ?? 0) + total.sum);
        }
        return { _tag: "totals", totals: [...sums].map(([start, sum]) => ({ start, sum })) };
      }
    }
  });

/** Runs a spec as an engine would, over in-memory data. */
export const run = (
  spec: CardSpec,
  range: CardRange,
  day: number,
  data: Data = {},
): CardRunData => {
  const ready = windowed(CardRun.forRange(spec, range, day, day, london), data);
  return ready.compute(fetch(ready, data));
};
