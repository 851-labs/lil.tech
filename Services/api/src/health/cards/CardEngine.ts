import { type HealthAggregation, healthCatalogType } from "../HealthCatalog.ts";
import { hourMillis } from "../tools/ToolTime.ts";
import {
  type CardCalendar,
  CardBucketer,
  type CardGrain,
  type CardInterval,
  bucketGrain,
  bucketStart,
  bucketStarts,
  grainEnd,
  grainStart,
  rangeIntervalContaining,
  timeOfDayStretches,
} from "./CardCalendar.ts";
import {
  type CardNight,
  type CardSleepRecord,
  asleepStretches,
  cardNights,
  fallingAsleep,
  nightBedtime,
  nightRecordRange,
  waking,
} from "./CardNights.ts";
import type {
  CardAggregation,
  CardFilter,
  CardFormula,
  CardRange,
  CardSeries,
  CardSpec,
  CardWindow,
} from "./CardSpec.ts";

// The server's card engine core (851-3197, `docs/decisions/cards.md`, What an engine computes): a
// port of the Swift `HealthCards` engine (`CardRun`, `CardReadings`, `CardWindows`), rule for
// rule, so the Mac and the server give the same `CardData` (851-3198's conformance cases check
// it). A run says what to fetch (`fetches`, and first `windowFetches` for sleep and workout
// windows), and computes the card from what was fetched (`compute`), over plain inputs; the
// store's fetching is `CardQueries.ts`. Times are Unix milliseconds. Sums are added in the Swift
// core's order, so the numbers match to the bit where the fetched rows come in the same order.

// MARK: - Inputs

/** One sample of a series' type with a value, as every engine reads it. */
export interface CardReading {
  readonly start: number;
  readonly end: number;
  /** In the type's catalog unit. */
  readonly value: number;
  /** The source's bundle ID: each source is its own series for time weighting. */
  readonly source: string;
  /** The sample's ID (a lowercase UUID), for `first`'s and `latest`'s ties; may be empty otherwise. */
  readonly sampleId: string;
}

/** A cumulative type's total over one bucket: Health's de-duplicated totals. */
export interface CardTotal {
  readonly start: number;
  readonly sum: number;
}

/** A stretch of time a window keeps readings in, half-open. */
export interface CardStretch {
  readonly start: number;
  readonly end: number;
}

/** A workout, as every engine reads it: its overall activity (`HKWorkoutActivityType`'s raw value). */
export interface CardWorkout {
  readonly start: number;
  readonly end: number;
  readonly activityType: number;
}

/** What a run needs fetched for one of its series. */
export interface CardFetch {
  /** The series' index in the spec. */
  readonly series: number;
  /** Its type's HealthKit identifier. */
  readonly type: string;
  /** The period's data, or the whole buckets before it a moving average needs (totals only). */
  readonly purpose: "period" | "history";
  readonly kind:
    | {
        /** A cumulative type's de-duplicated totals per bucket of `grain`, from buckets starting in the range. */
        readonly _tag: "totals";
        readonly range: CardInterval;
        readonly grain: CardGrain;
      }
    | {
        /**
         * The type's readings starting in the range, oldest first, that match the filter.
         * `needsSampleIds`: whether `CardReading.sampleId` is used (`first` and `latest`).
         */
        readonly _tag: "readings";
        readonly range: CardInterval;
        readonly filter: CardFilter | null;
        readonly needsSampleIds: boolean;
      }
    | {
        /**
         * The same, for a sleep or workout window once windowed: the readings starting in one of
         * the stretches (in order and apart). Readings outside them may be included: the run keeps
         * those in a stretch.
         */
        readonly _tag: "stretchReadings";
        readonly stretches: ReadonlyArray<CardStretch>;
        readonly filter: CardFilter | null;
        readonly needsSampleIds: boolean;
      };
}

/** What was fetched for a `CardFetch`: totals for `totals`, readings (oldest first) for the others. */
export type CardFetchResult =
  | { readonly _tag: "totals"; readonly totals: ReadonlyArray<CardTotal> }
  | { readonly _tag: "readings"; readonly readings: ReadonlyArray<CardReading> };

/**
 * What a run with sleep or workout windows fetches before their readings: sleep analysis records
 * (every value and source) and workouts (every activity) that end after the range starts and start
 * before it ends, by start.
 */
export type CardWindowFetch =
  | { readonly _tag: "sleep"; readonly range: CardInterval }
  | { readonly _tag: "workouts"; readonly range: CardInterval };

export type CardWindowFetchResult =
  | { readonly _tag: "sleep"; readonly records: ReadonlyArray<CardSleepRecord> }
  | { readonly _tag: "workouts"; readonly workouts: ReadonlyArray<CardWorkout> };

// MARK: - Outputs

/** One bucket of a series. */
export interface CardPoint {
  readonly start: number;
  /** By the series' aggregation. */
  readonly value: number;
  /** The bucket's lowest and highest readings: `value` for totals and counts. */
  readonly minimum: number;
  readonly maximum: number;
  /** How many readings it has; null for totals. */
  readonly readings: number | null;
}

export interface CardFormulaPoint {
  readonly start: number;
  readonly value: number;
}

export type CardSummaryKind =
  | "total"
  | "average"
  | "dailyAverage"
  | "range"
  | "lowest"
  | "highest"
  | "first"
  | "latest"
  | "count";

/** What the page's header shows for the period, from the lead. */
export interface CardSummary {
  readonly kind: CardSummaryKind;
  /** Null for a range. */
  readonly value: number | null;
  /** A range's lowest and highest readings; null otherwise. */
  readonly minimum: number | null;
  readonly maximum: number | null;
}

/** A run's result (the Swift core's `CardData`), times in Unix milliseconds. */
export interface CardRunData {
  /** The range it was run for, or null for a headline's buckets. */
  readonly range: CardRange | null;
  readonly interval: CardInterval;
  readonly grain: CardGrain;
  readonly series: ReadonlyArray<{
    readonly id: string;
    /** The series' label, or its type's name. */
    readonly label: string;
    readonly type: string;
    readonly aggregation: CardAggregation;
    /** Its value unit: the type's catalog unit, or `count` for a count. */
    readonly unit: string;
    readonly hidden: boolean;
    readonly points: ReadonlyArray<CardPoint>;
  }>;
  readonly formulas: ReadonlyArray<{
    readonly id: string;
    readonly kind: CardFormula["kind"];
    readonly label: string | null;
    readonly unit: string;
    readonly hidden: boolean;
    readonly points: ReadonlyArray<CardFormulaPoint>;
  }>;
  /** Null when the period has no data (No Data). */
  readonly summary: CardSummary | null;
  /** The goal's value, in the lead's value unit. */
  readonly goal: number | null;
}

// MARK: - The spec

/** A count's value unit: a number of readings, whatever the type. */
export const readingsUnit = "count";

const aggregationOf = (series: CardSeries): HealthAggregation =>
  healthCatalogType(series.type)?.aggregation ?? "discreteArithmetic";

/** A series' value unit: its type's catalog unit, except for `count`. */
export const seriesUnit = (series: CardSeries): string =>
  series.aggregation === "count" ? readingsUnit : (healthCatalogType(series.type)?.unit ?? "");

/** The series a formula's unit and type come from: its (first) series. */
const leadingSeries = (spec: CardSpec, formula: CardFormula): CardSeries | undefined => {
  const id = formula.kind === "movingAverage" ? formula.of : formula.of[0];
  return spec.series.find((series) => series.id === id);
};

/** The first visible series, or with every series hidden, the first visible formula. */
export type CardLead =
  | { readonly _tag: "series"; readonly series: CardSeries }
  | { readonly _tag: "formula"; readonly formula: CardFormula };

export const cardLead = (spec: CardSpec): CardLead | undefined => {
  const series = spec.series.find((candidate) => !candidate.hidden);
  if (series !== undefined) return { _tag: "series", series };
  const formula = spec.formulas.find((candidate) => !candidate.hidden);
  return formula === undefined ? undefined : { _tag: "formula", formula };
};

const isSleepWindow = (window: CardWindow | null) =>
  window !== null &&
  (window.kind === "asleep" || window.kind === "beforeSleep" || window.kind === "afterWaking");

// MARK: - Weights

/** The longest a reading counts for in a time-weighted average. */
export const maxSampleWeightMillis = hourMillis;
const maxSampleWeight = maxSampleWeightMillis / 1000;

const clampWeight = (millis: number) => Math.min(Math.max(millis / 1000, 1), maxSampleWeight);

/**
 * Numbers for the few sources a type's readings come from, in the order they're met. A source
 * usually repeats the one before, which is compared first.
 */
class CardSources {
  private readonly indices = new Map<string, number>();
  private last: string | undefined;
  private lastIndex = -1;

  index(source: string): number {
    if (source === this.last) return this.lastIndex;
    let index = this.indices.get(source);
    if (index === undefined) {
      index = this.indices.size;
      this.indices.set(source, index);
    }
    this.last = source;
    this.lastIndex = index;
    return index;
  }
}

/**
 * Each reading's weight in an average, in seconds, for readings oldest first:
 * - Time-weighted: until its source's next reading, or for its own duration if it's the source's
 *   last, at least 1 s and at most an hour.
 * - Equivalent continuous level (sound): its duration, at least 1 s.
 * - Arithmetic: 1 each.
 */
export const cardWeights = (
  readings: ReadonlyArray<CardReading>,
  aggregation: HealthAggregation,
): Float64Array => {
  const weights = new Float64Array(readings.length).fill(1);
  if (aggregation === "discreteTemporallyWeighted") {
    const sources = new CardSources();
    const nextStart: Array<number | undefined> = [];
    for (let index = readings.length - 1; index >= 0; index--) {
      const reading = readings[index]!;
      const source = sources.index(reading.source);
      const until = nextStart[source] ?? reading.end;
      weights[index] = clampWeight(until - reading.start);
      nextStart[source] = reading.start;
    }
  } else if (aggregation === "discreteEquivalentContinuousLevel") {
    for (let index = 0; index < readings.length; index++) {
      const reading = readings[index]!;
      weights[index] = Math.max((reading.end - reading.start) / 1000, 1);
    }
  }
  return weights;
};

/**
 * Weights in a window, for readings oldest first, each with the index of the stretch it starts in.
 * Time-weighted readings count until their source's next reading in the same stretch, or else the
 * stretch's end, at least 1 s and at most an hour. Other styles weigh as without a window.
 */
export const cardWindowWeights = (
  readings: ReadonlyArray<CardReading>,
  stretches: ReadonlyArray<CardStretch>,
  stretchIndices: ReadonlyArray<number>,
  aggregation: HealthAggregation,
): Float64Array => {
  if (aggregation !== "discreteTemporallyWeighted") return cardWeights(readings, aggregation);
  const weights = new Float64Array(readings.length);
  const sources = new CardSources();
  const nextStretch: Array<number> = [];
  const nextStart: Array<number> = [];
  for (let index = readings.length - 1; index >= 0; index--) {
    const reading = readings[index]!;
    const stretch = stretchIndices[index]!;
    const source = sources.index(reading.source);
    const until = nextStretch[source] === stretch ? nextStart[source]! : stretches[stretch]!.end;
    weights[index] = clampWeight(until - reading.start);
    nextStretch[source] = stretch;
    nextStart[source] = reading.start;
  }
  return weights;
};

/** A weighted average built a reading at a time, in order: an energy average for sound levels. */
class Accumulator {
  readonly isEnergy: boolean;
  weighted = 0;
  total = 0;

  constructor(aggregation: HealthAggregation) {
    this.isEnergy = aggregation === "discreteEquivalentContinuousLevel";
  }

  add(value: number, weight: number) {
    this.weighted += this.isEnergy ? weight * 10 ** (value / 10) : value * weight;
    this.total += weight;
  }

  /** 0 without weight. */
  get average(): number {
    if (!(this.total > 0)) return 0;
    return this.isEnergy ? 10 * Math.log10(this.weighted / this.total) : this.weighted / this.total;
  }
}

/** Whether `a` comes before `b`: by start, then end, then sample ID. */
const startsBefore = (a: CardReading, b: CardReading) =>
  a.start !== b.start
    ? a.start < b.start
    : a.end !== b.end
      ? a.end < b.end
      : a.sampleId < b.sampleId;

/** A bucket's readings, aggregated as they come (oldest first): what every aggregation needs. */
class Bucket {
  readonly average: Accumulator;
  readonly keepsOrder: boolean;
  count = 0;
  minimum = Infinity;
  maximum = -Infinity;
  first: CardReading | undefined;
  latest: CardReading | undefined;

  constructor(aggregation: HealthAggregation, keepsOrder: boolean) {
    this.average = new Accumulator(aggregation);
    this.keepsOrder = keepsOrder;
  }

  add(reading: CardReading, weight: number) {
    this.average.add(reading.value, weight);
    this.count++;
    this.minimum = Math.min(this.minimum, reading.value);
    this.maximum = Math.max(this.maximum, reading.value);
    if (!this.keepsOrder) return;
    if (this.first === undefined || startsBefore(reading, this.first)) this.first = reading;
    if (this.latest === undefined || startsBefore(this.latest, reading)) this.latest = reading;
  }

  /** The bucket's value by `aggregation`; undefined without readings (and for totals). */
  value(aggregation: CardAggregation): number | undefined {
    if (this.count === 0) return undefined;
    switch (aggregation) {
      case "avg":
        return this.average.average;
      case "min":
        return this.minimum;
      case "max":
        return this.maximum;
      case "first":
        return this.first?.value;
      case "latest":
        return this.latest?.value;
      case "count":
        return this.count;
      case "sum":
        return undefined;
    }
  }
}

/**
 * Buckets by start, added to as readings come: in order but for nights whose stretches overlap,
 * whose readings can come back to a bucket.
 */
class Buckets {
  private readonly list: Array<{ readonly start: number; readonly bucket: Bucket }> = [];
  private readonly index = new Map<number, number>();
  private inOrder = true;

  add(reading: CardReading, weight: number, start: number, make: () => Bucket) {
    const last = this.list.at(-1);
    if (last?.start === start) {
      last.bucket.add(reading, weight);
      return;
    }
    const existing = this.index.get(start);
    if (existing !== undefined) {
      this.list[existing]!.bucket.add(reading, weight);
      return;
    }
    if (last !== undefined && start < last.start) this.inOrder = false;
    this.index.set(start, this.list.length);
    const bucket = make();
    bucket.add(reading, weight);
    this.list.push({ start, bucket });
  }

  get sorted(): ReadonlyArray<{ readonly start: number; readonly bucket: Bucket }> {
    return this.inOrder ? this.list : [...this.list].sort((a, b) => a.start - b.start);
  }
}

// MARK: - Windows

/**
 * The readings (oldest first) whose start is in one of `stretches` (in order, apart), with the
 * index of the stretch each is in.
 */
export const readingsInStretches = (
  readings: ReadonlyArray<CardReading>,
  stretches: ReadonlyArray<CardStretch>,
): { readonly readings: Array<CardReading>; readonly stretchIndices: Array<number> } => {
  const kept: Array<CardReading> = [];
  const stretchIndices: Array<number> = [];
  let stretch = 0;
  for (const reading of readings) {
    while (stretch < stretches.length && stretches[stretch]!.end <= reading.start) stretch++;
    if (stretch >= stretches.length) break;
    if (stretches[stretch]!.start <= reading.start) {
      kept.push(reading);
      stretchIndices.push(stretch);
    }
  }
  return { readings: kept, stretchIndices };
};

interface OwnedStretch {
  readonly stretch: CardStretch;
  /** The night's index. */
  readonly night: number;
}

/**
 * Stretches made apart, by start: where several overlap, the one with the greatest owner keeps the
 * overlap. One owner's stretches are apart already.
 */
export const latestOwnerWins = (stretches: ReadonlyArray<OwnedStretch>): Array<OwnedStretch> => {
  const sorted = stretches
    .filter(({ stretch }) => stretch.start < stretch.end)
    .sort((a, b) => a.stretch.start - b.stretch.start || a.night - b.night);
  // Nothing overlaps, as almost always: sorted, they're the answer.
  if (
    !sorted.some(
      (owned, index) => index > 0 && sorted[index - 1]!.stretch.end > owned.stretch.start,
    )
  ) {
    return sorted;
  }
  // A sweep over every start and end: between two of them, the greatest owner among the stretches
  // open there keeps the time.
  const events = sorted
    .flatMap(({ stretch, night }) => [
      { time: stretch.start, opens: true, night },
      { time: stretch.end, opens: false, night },
    ])
    .sort((a, b) => a.time - b.time);
  const open = new Map<number, number>();
  const resolved: Array<{ stretch: { start: number; end: number }; night: number }> = [];
  let index = 0;
  let previous: number | undefined;
  while (index < events.length) {
    const time = events[index]!.time;
    if (previous !== undefined && open.size > 0 && previous < time) {
      const owner = Math.max(...open.keys());
      const last = resolved.at(-1);
      if (last !== undefined && last.night === owner && last.stretch.end === previous) {
        last.stretch.end = time;
      } else {
        resolved.push({ stretch: { start: previous, end: time }, night: owner });
      }
    }
    while (index < events.length && events[index]!.time === time) {
      const event = events[index]!;
      const count = (open.get(event.night) ?? 0) + (event.opens ? 1 : -1);
      if (count === 0) open.delete(event.night);
      else open.set(event.night, count);
      index++;
    }
    previous = time;
  }
  return resolved;
};

/**
 * A sleep window's stretches over `nights` (by day), in order and apart, each with the night (its
 * day) it belongs to. Only nights' sleep: a day's has none.
 */
export const sleepStretches = (
  window: CardWindow,
  nights: ReadonlyArray<CardNight>,
  calendar: CardCalendar,
): { readonly stretches: Array<CardStretch>; readonly nights: Array<number> } => {
  const owned: Array<OwnedStretch> = [];
  nights.forEach((night, index) => {
    if (nightBedtime(night, calendar) === undefined) return;
    switch (window.kind) {
      case "asleep":
        for (const stretch of asleepStretches(night)) owned.push({ stretch, night: index });
        break;
      case "beforeSleep": {
        const start = fallingAsleep(night);
        if (start !== undefined) {
          owned.push({
            stretch: { start: start - window.minutes * 60_000, end: start },
            night: index,
          });
        }
        break;
      }
      case "afterWaking": {
        const end = waking(night);
        if (end !== undefined) {
          owned.push({ stretch: { start: end, end: end + window.minutes * 60_000 }, night: index });
        }
        break;
      }
      case "workout":
      case "timeOfDay":
        break;
    }
  });
  const resolved = latestOwnerWins(owned);
  return {
    stretches: resolved.map(({ stretch }) => stretch),
    nights: resolved.map(({ night }) => nights[night]!.day),
  };
};

/**
 * A workout window's stretches: each matching workout's `[start, end)` (of `activities`, or every
 * one), merged where they overlap or touch, and clipped to `span`.
 */
export const workoutStretches = (
  activities: ReadonlyArray<number> | null,
  workouts: ReadonlyArray<CardWorkout>,
  span: CardInterval,
): Array<CardStretch> => {
  const matching = workouts
    .filter((workout) => activities === null || activities.includes(workout.activityType))
    .sort((a, b) => a.start - b.start || a.end - b.end);
  const stretches: Array<{ start: number; end: number }> = [];
  for (const workout of matching) {
    const start = Math.max(workout.start, span.start);
    const end = Math.min(workout.end, span.end);
    if (start >= end) continue;
    const last = stretches.at(-1);
    if (last !== undefined && start <= last.end) last.end = Math.max(last.end, end);
    else stretches.push({ start, end });
  }
  return stretches;
};

// MARK: - Totals

/**
 * The average day of each bucket of `grain` (a week for 6M, a month for Y), among `days` (in order)
 * that have a total: Health's DAILY AVERAGE, and Metric Detail's.
 */
export const averageDays = (
  days: ReadonlyArray<CardTotal>,
  grain: CardGrain,
  calendar: CardCalendar,
): Array<CardFormulaPoint> => {
  const groups: Array<{ start: number; sum: number; days: number }> = [];
  const bucketer = new CardBucketer(calendar, grain);
  for (const day of days) {
    const start = bucketer.startOf(day.start);
    const last = groups.at(-1);
    if (last?.start === start) {
      last.sum += day.sum;
      last.days += 1;
    } else {
      groups.push({ start, sum: day.sum, days: 1 });
    }
  }
  return groups.map(({ start, sum, days: count }) => ({ start, value: sum / count }));
};

// MARK: - The run

/** A sleep or workout window's stretches for one series, and for a sleep window each one's night. */
interface Stretches {
  readonly stretches: ReadonlyArray<CardStretch>;
  readonly nights: ReadonlyArray<number> | undefined;
}

/** A series' points, and what its summary and formulas need. */
interface Computed {
  points: Array<CardPoint>;
  /** Values of the whole buckets before the period, by start, for moving averages. */
  history: Map<number, number>;
  /** The period's totals as fetched (days, for an average day), above 0. */
  totals: Array<CardTotal>;
  /** Every reading in the period. */
  period: Bucket | undefined;
}

/**
 * A card spec run over one period, the engine's core (the Swift `CardRun`):
 *
 * ```ts
 * let run = CardRun.forRange(spec, range, date, now, calendar)
 * if (run.windowFetches.length > 0) run = run.windowed(run.windowFetches.map(fetchWindow))
 * const data = run.compute(run.fetches.map(fetch))
 * ```
 *
 * Sleep and workout windows take two steps: their nights' sleep records and their workouts first
 * (`windowFetches`), which `windowed` turns into stretches, then only the readings in those
 * stretches. Until it's windowed, a series with one fetches nothing and has no points.
 */
export class CardRun {
  readonly spec: CardSpec;
  /** The range it's for, or null for a headline's buckets. */
  readonly range: CardRange | null;
  /** The period: only readings starting in it count. */
  readonly interval: CardInterval;
  readonly grain: CardGrain;
  readonly calendar: CardCalendar;
  /** What to fetch, in the spec's series order. `compute` takes a result for each. */
  readonly fetches: ReadonlyArray<CardFetch>;
  /** What sleep and workout windows need first. Empty when none has one, or once windowed. */
  readonly windowFetches: ReadonlyArray<CardWindowFetch>;
  private readonly windows: ReadonlyMap<number, Stretches>;
  /** Each series' `history`, by ID, worked out once: it costs time-zone math. */
  private readonly histories = new Map<string, CardInterval | undefined>();

  /** `windows`: each windowed series' stretches, or undefined before `windowed`. */
  private constructor(
    spec: CardSpec,
    range: CardRange | null,
    interval: CardInterval,
    grain: CardGrain,
    calendar: CardCalendar,
    windows: ReadonlyMap<number, Stretches> | undefined,
  ) {
    this.spec = spec;
    this.range = range;
    this.interval = interval;
    this.grain = grain;
    this.calendar = calendar;
    this.windows = windows ?? new Map();
    this.fetches = spec.series.flatMap((series, index) =>
      this.seriesFetches(series, index, windows?.get(index)),
    );
    this.windowFetches = windows === undefined ? this.windowFetchesOf() : [];
  }

  /**
   * The period of `range` containing `date`, as a card's page shows it. `now` places 6M's periods:
   * the six months ending with its month, then the six before them.
   */
  static forRange(
    spec: CardSpec,
    range: CardRange,
    date: number,
    now: number,
    calendar: CardCalendar,
  ): CardRun {
    return new CardRun(
      spec,
      range,
      rangeIntervalContaining(calendar, range, date, now),
      bucketGrain(spec.bucket, range),
      calendar,
      undefined,
    );
  }

  /**
   * The `buckets` buckets ending with the one containing `date`, as a Summary row's sparkline
   * shows them: the card's buckets, with `auto` as days.
   */
  static forHeadline(
    spec: CardSpec,
    date: number,
    calendar: CardCalendar,
    buckets = sparklineBuckets,
  ): CardRun {
    const grain = headlineGrain(spec);
    const start = bucketStart(calendar, grain, buckets - 1, date);
    const end = grainEnd(calendar, grain, grainStart(calendar, grain, date));
    return new CardRun(spec, null, { start, end }, grain, calendar, undefined);
  }

  // MARK: Windows

  /**
   * The whole buckets before the period a moving average of the series needs, so its first points
   * have their full window; undefined when none does.
   */
  private history(series: CardSeries): CardInterval | undefined {
    if (this.histories.has(series.id)) return this.histories.get(series.id);
    const history = this.historyOf(series);
    this.histories.set(series.id, history);
    return history;
  }

  private historyOf(series: CardSeries): CardInterval | undefined {
    let points: number | undefined;
    for (const formula of this.spec.formulas) {
      if (formula.kind === "movingAverage" && formula.of === series.id) {
        points = Math.max(points ?? formula.points, formula.points);
      }
    }
    if (points === undefined || points <= 1) return undefined;
    const first = bucketStart(this.calendar, this.grain, 0, this.interval.start);
    const start = bucketStart(this.calendar, this.grain, points - 1, this.interval.start);
    return start < first ? { start, end: first } : undefined;
  }

  /**
   * Where a windowed series' readings can come from: its period, and the whole buckets before it
   * its moving average needs. For a sleep window, the days whose nights count.
   */
  private windowSpan(series: CardSeries): CardInterval {
    return { start: this.history(series)?.start ?? this.interval.start, end: this.interval.end };
  }

  /** The days whose nights the sleep windows need, and the span the workout windows do. */
  private windowSpans(): { nights?: CardInterval; workouts?: CardInterval } {
    let nights: CardInterval | undefined;
    let workouts: CardInterval | undefined;
    const widen = (span: CardInterval | undefined, own: CardInterval) =>
      span === undefined
        ? own
        : { start: Math.min(span.start, own.start), end: Math.max(span.end, own.end) };
    for (const series of this.spec.series) {
      if (series.aggregation === "sum" || series.window === null) continue;
      if (isSleepWindow(series.window)) nights = widen(nights, this.windowSpan(series));
      else if (series.window.kind === "workout")
        workouts = widen(workouts, this.windowSpan(series));
    }
    return { ...(nights && { nights }), ...(workouts && { workouts }) };
  }

  private windowFetchesOf(): Array<CardWindowFetch> {
    const spans = this.windowSpans();
    const fetches: Array<CardWindowFetch> = [];
    if (spans.nights !== undefined)
      fetches.push({ _tag: "sleep", range: nightRecordRange(spans.nights) });
    if (spans.workouts !== undefined) fetches.push({ _tag: "workouts", range: spans.workouts });
    return fetches;
  }

  /**
   * The run with its sleep and workout windows' stretches, from a result for each of
   * `windowFetches`, in their order: its `fetches` then read each windowed series' readings in its
   * stretches. A run without window fetches, or windowed already, is returned as it is.
   */
  windowed(results: ReadonlyArray<CardWindowFetchResult>): CardRun {
    if (this.windowFetches.length === 0) return this;
    if (results.length !== this.windowFetches.length) {
      throw new Error("A result for each window fetch.");
    }
    let records: ReadonlyArray<CardSleepRecord> = [];
    let workouts: ReadonlyArray<CardWorkout> = [];
    this.windowFetches.forEach((fetch, index) => {
      const result = results[index]!;
      if (fetch._tag === "sleep" && result._tag === "sleep") records = result.records;
      else if (fetch._tag === "workouts" && result._tag === "workouts") workouts = result.workouts;
      else throw new Error("A result of each window fetch's kind.");
    });
    const days = this.windowSpans().nights;
    const nights = days === undefined ? [] : cardNights(records, days, this.calendar);
    // A bucket that starts before the period counts only the period's nights (6M's first week),
    // and a moving average's buckets are whole ones before it.
    const firstBucket = bucketStart(this.calendar, this.grain, 0, this.interval.start);
    const windows = new Map<number, Stretches>();
    this.spec.series.forEach((series, index) => {
      const window = series.window;
      if (series.aggregation === "sum" || window === null) return;
      const span = this.windowSpan(series);
      if (isSleepWindow(window)) {
        const { stretches, nights: owners } = sleepStretches(
          window,
          nights.filter(
            (night) =>
              night.day >= span.start &&
              night.day < span.end &&
              (night.day >= this.interval.start || night.day < firstBucket),
          ),
          this.calendar,
        );
        windows.set(index, { stretches, nights: owners });
      } else if (window.kind === "workout") {
        // Up to the longest weight past the period, which is all its last readings' weights need.
        windows.set(index, {
          stretches: workoutStretches(window.activities, workouts, {
            start: span.start,
            end: this.interval.end + maxSampleWeightMillis,
          }),
          nights: undefined,
        });
      }
    });
    return new CardRun(this.spec, this.range, this.interval, this.grain, this.calendar, windows);
  }

  // MARK: What to fetch

  /** Whether a series' points are the average day of each week or month: a total with `auto` at 6M or Y. */
  private averagesDays(series: CardSeries): boolean {
    return (
      series.aggregation === "sum" &&
      this.spec.bucket === "auto" &&
      (this.range === "6M" || this.range === "Y")
    );
  }

  private seriesFetches(
    series: CardSeries,
    index: number,
    stretches: Stretches | undefined,
  ): Array<CardFetch> {
    const history = this.history(series);
    const { type } = series;
    if (series.aggregation === "sum") {
      const grain = this.averagesDays(series) ? "day" : this.grain;
      const fetches: Array<CardFetch> = [
        {
          series: index,
          type,
          purpose: "period",
          kind: { _tag: "totals", range: this.interval, grain },
        },
      ];
      if (history !== undefined) {
        fetches.push({
          series: index,
          type,
          purpose: "history",
          kind: { _tag: "totals", range: history, grain },
        });
      }
      return fetches;
    }
    const needsSampleIds = series.aggregation === "first" || series.aggregation === "latest";
    if (series.window !== null && series.window.kind !== "timeOfDay") {
      // Only once windowed: the readings in its stretches.
      if (stretches === undefined) return [];
      return [
        {
          series: index,
          type,
          purpose: "period",
          kind: {
            _tag: "stretchReadings",
            stretches: stretches.stretches,
            filter: series.filter,
            needsSampleIds,
          },
        },
      ];
    }
    const start = history?.start ?? this.interval.start;
    // The next reading after the period's last, for its weight.
    const end =
      this.interval.end +
      (aggregationOf(series) === "discreteTemporallyWeighted" ? maxSampleWeightMillis : 0);
    return [
      {
        series: index,
        type,
        purpose: "period",
        kind: { _tag: "readings", range: { start, end }, filter: series.filter, needsSampleIds },
      },
    ];
  }

  // MARK: Computing

  /** The card's data from a result for each of `fetches`, in their order. */
  compute(results: ReadonlyArray<CardFetchResult>): CardRunData {
    if (results.length !== this.fetches.length) throw new Error("A result for each fetch.");
    const computed: Array<Computed> = this.spec.series.map(() => ({
      points: [],
      history: new Map(),
      totals: [],
      period: undefined,
    }));
    this.fetches.forEach((fetch, index) => {
      const result = results[index]!;
      const series = this.spec.series[fetch.series]!;
      const target = computed[fetch.series]!;
      if (result._tag === "totals") this.addTotals(target, result.totals, fetch.purpose, series);
      else this.addReadings(target, result.readings, series, this.windows.get(fetch.series));
    });
    const formulas = this.spec.formulas.map((formula) => ({
      id: formula.id,
      kind: formula.kind,
      label: formula.label,
      unit: (() => {
        const series = leadingSeries(this.spec, formula);
        return series === undefined ? readingsUnit : seriesUnit(series);
      })(),
      hidden: formula.hidden,
      points: this.formulaPoints(formula, computed),
    }));
    return {
      range: this.range,
      interval: this.interval,
      grain: this.grain,
      series: this.spec.series.map((series, index) => ({
        id: series.id,
        label: series.label ?? healthCatalogType(series.type)?.name ?? series.type,
        type: series.type,
        aggregation: series.aggregation,
        unit: seriesUnit(series),
        hidden: series.hidden,
        points: computed[index]!.points,
      })),
      formulas,
      summary: this.summary(computed, formulas),
      goal: this.spec.chart.goal?.value ?? null,
    };
  }

  private addTotals(
    computed: Computed,
    fetched: ReadonlyArray<CardTotal>,
    purpose: CardFetch["purpose"],
    series: CardSeries,
  ) {
    // Days with a total above 0 are the ones with data.
    const totals = fetched.filter((total) => total.sum > 0).sort((a, b) => a.start - b.start);
    const points = this.averagesDays(series)
      ? averageDays(totals, this.grain, this.calendar)
      : totals.map((total) => ({ start: total.start, value: total.sum }));
    if (purpose === "period") {
      computed.totals = totals;
      computed.points = points.map(({ start, value }) => ({
        start,
        value,
        minimum: value,
        maximum: value,
        readings: null,
      }));
    } else {
      for (const point of points) computed.history.set(point.start, point.value);
    }
  }

  /** `stretches`: a sleep or workout window's. */
  private addReadings(
    computed: Computed,
    fetched: ReadonlyArray<CardReading>,
    series: CardSeries,
    stretches: Stretches | undefined,
  ) {
    const aggregation = aggregationOf(series);
    const keepsOrder = series.aggregation === "first" || series.aggregation === "latest";
    let readings = fetched;
    let weights: Float64Array;
    // Where each reading goes, when it isn't its start: its night's day.
    let places: Array<number> | undefined;
    const window = series.window;
    if (stretches !== undefined) {
      const kept = readingsInStretches(readings, stretches.stretches);
      readings = kept.readings;
      weights = cardWindowWeights(readings, stretches.stretches, kept.stretchIndices, aggregation);
      const nights = stretches.nights;
      if (nights !== undefined) places = kept.stretchIndices.map((index) => nights[index]!);
    } else if (window?.kind === "timeOfDay" && readings.length > 0) {
      // A stretch past the last reading only matters up to the longest weight.
      const reach = maxSampleWeightMillis + 1;
      const own = timeOfDayStretches(
        window,
        { start: readings[0]!.start, end: readings.at(-1)!.start + reach },
        this.calendar.zone,
      );
      const kept = readingsInStretches(readings, own);
      readings = kept.readings;
      weights = cardWindowWeights(readings, own, kept.stretchIndices, aggregation);
    } else {
      weights = cardWeights(readings, aggregation);
    }

    const periodStart = this.interval.start;
    const periodEnd = this.interval.end;
    const firstBucket = bucketStart(this.calendar, this.grain, 0, this.interval.start);
    const bucketer = new CardBucketer(this.calendar, this.grain);
    const buckets = new Buckets();
    const earlier = new Buckets();
    const period = new Bucket(aggregation, keepsOrder);
    const make = () => new Bucket(aggregation, keepsOrder);
    for (let index = 0; index < readings.length; index++) {
      const reading = readings[index]!;
      const weight = weights[index]!;
      const place = places?.[index] ?? reading.start;
      if (place >= periodEnd) {
        // Readings come by start, and so do their places, but nights' days needn't.
        if (places === undefined) break;
        continue;
      }
      if (place >= periodStart) {
        buckets.add(reading, weight, bucketer.startOf(place), make);
        period.add(reading, weight);
      } else if (place < firstBucket) {
        earlier.add(reading, weight, bucketer.startOf(place), make);
      }
    }
    const isCount = series.aggregation === "count";
    computed.points = buckets.sorted.flatMap(({ start, bucket }) => {
      const value = bucket.value(series.aggregation);
      if (value === undefined) return [];
      return [
        {
          start,
          value,
          minimum: isCount ? value : bucket.minimum,
          maximum: isCount ? value : bucket.maximum,
          readings: bucket.count,
        },
      ];
    });
    for (const { start, bucket } of earlier.sorted) {
      const value = bucket.value(series.aggregation);
      if (value !== undefined) computed.history.set(start, value);
    }
    computed.period = period.count > 0 ? period : undefined;
  }

  // MARK: Formulas

  private formulaPoints(
    formula: CardFormula,
    computed: ReadonlyArray<Computed>,
  ): Array<CardFormulaPoint> {
    const seriesById = (id: string) => {
      const index = this.spec.series.findIndex((series) => series.id === id);
      return index < 0 ? undefined : computed[index];
    };
    if (formula.kind === "movingAverage") {
      const series = seriesById(formula.of);
      const firstPoint = series?.points[0];
      if (series === undefined || firstPoint === undefined) return [];
      const count = formula.points;
      // Every bucket from the earliest the window reaches, empty ones included.
      const starts = bucketStarts(
        this.calendar,
        this.grain,
        bucketStart(this.calendar, this.grain, count - 1, firstPoint.start),
        this.interval.end,
      );
      const values = new Map(series.history);
      for (const point of series.points) values.set(point.start, point.value);
      const positions = new Map<number, number>();
      starts.forEach((start, position) => {
        if (!positions.has(start)) positions.set(start, position);
      });
      return series.points.flatMap((point) => {
        const position = positions.get(point.start);
        if (position === undefined) return [];
        let sum = 0;
        let found = 0;
        for (let at = Math.max(0, position - count + 1); at <= position; at++) {
          const value = values.get(starts[at]!);
          if (value === undefined) continue;
          sum += value;
          found++;
        }
        return [{ start: point.start, value: sum / found }];
      });
    }
    const minuend = seriesById(formula.of[0]!);
    const subtrahend = seriesById(formula.of[1]!);
    if (minuend === undefined || subtrahend === undefined) return [];
    const values = new Map<number, number>();
    for (const point of subtrahend.points) {
      if (!values.has(point.start)) values.set(point.start, point.value);
    }
    return minuend.points.flatMap((point) => {
      const value = values.get(point.start);
      return value === undefined ? [] : [{ start: point.start, value: point.value - value }];
    });
  }

  // MARK: Summary

  private summary(
    computed: ReadonlyArray<Computed>,
    formulas: ReadonlyArray<{
      readonly id: string;
      readonly points: ReadonlyArray<CardFormulaPoint>;
    }>,
  ): CardSummary | null {
    const lead = cardLead(this.spec);
    const summary = (
      kind: CardSummaryKind,
      value: number | null,
      minimum: number | null = null,
      maximum: number | null = null,
    ): CardSummary => ({ kind, value, minimum, maximum });
    if (lead === undefined) return null;
    if (lead._tag === "formula") {
      const points = formulas.find((formula) => formula.id === lead.formula.id)?.points;
      if (points === undefined || points.length === 0) return null;
      return summary(
        "average",
        points.reduce((total, point) => total + point.value, 0) / points.length,
      );
    }
    const index = this.spec.series.indexOf(lead.series);
    const series = computed[index];
    if (series === undefined) return null;
    if (lead.series.aggregation === "sum") return this.totalSummary(series);
    const period = series.period;
    if (period === undefined) return null;
    switch (lead.series.aggregation) {
      case "avg":
        if (this.spec.chart.style === "ranges") {
          // As Metric Detail: a range, unless every reading was the same.
          return period.minimum === period.maximum
            ? summary("average", period.minimum)
            : summary("range", null, period.minimum, period.maximum);
        }
        return summary("average", period.average.average);
      case "min":
        return summary("lowest", period.minimum);
      case "max":
        return summary("highest", period.maximum);
      case "first":
        return summary("first", period.first?.value ?? null);
      case "latest":
        return summary("latest", period.latest?.value ?? null);
      case "count":
        return summary("count", period.count);
    }
  }

  /**
   * A total's header: a day's total at D, else its average day (or bucket) with data, as Metric
   * Detail's AVERAGE and DAILY AVERAGE.
   */
  private totalSummary(computed: Computed): CardSummary | null {
    const totals = computed.totals;
    if (totals.length === 0) return null;
    const total = totals.reduce((sum, item) => sum + item.sum, 0);
    const average = total / totals.length;
    const summary = (kind: CardSummaryKind, value: number): CardSummary => ({
      kind,
      value,
      minimum: null,
      maximum: null,
    });
    if (this.spec.bucket === "auto" && this.range !== null) {
      switch (this.range) {
        case "D":
          return summary("total", total);
        case "W":
        case "M":
          return summary("average", average);
        case "6M":
        case "Y":
          return summary("dailyAverage", average);
      }
    }
    const buckets = bucketStarts(
      this.calendar,
      this.grain,
      this.interval.start,
      this.interval.end,
    ).length;
    return buckets === 1 ? summary("total", total) : summary("average", average);
  }
}

// MARK: - Headlines

/** The buckets a sparkline shows. */
export const sparklineBuckets = 7;
/** How many runs a search tries before it's No Data: 8 weeks of days. */
export const headlineSearchRounds = 8;

/** A sparkline's buckets: the card's, with `auto` as days. */
export const headlineGrain = (spec: CardSpec): CardGrain =>
  spec.bucket === "auto" ? "day" : bucketGrain(spec.bucket, "W");

/** How a card's headline is found (the Swift `CardSpec.HeadlineLookup`). */
export type CardHeadlineLookup =
  /** The type's latest reading and when it was, as Summary shows heart rate and weight. */
  | { readonly _tag: "latestReading"; readonly type: string }
  /** The latest bucket, found from the type's latest data, as Summary shows a day's steps. */
  | { readonly _tag: "latestData"; readonly type: string }
  /** Runs back from now, for a lead with a window or filter, or a formula. */
  | { readonly _tag: "search" };

/**
 * How the card's headline is found: a lead that's a discrete series, `avg` or `latest`, `auto`,
 * with no window, filter or formula, shows its latest reading; another without a window or filter,
 * its latest bucket; the rest search. Undefined with nothing visible.
 */
export const headlineLookup = (spec: CardSpec): CardHeadlineLookup | undefined => {
  const lead = cardLead(spec);
  if (lead === undefined) return undefined;
  if (lead._tag === "formula") return { _tag: "search" };
  const { series } = lead;
  if (series.window !== null || series.filter !== null) return { _tag: "search" };
  if (
    (series.aggregation === "avg" || series.aggregation === "latest") &&
    spec.bucket === "auto" &&
    spec.formulas.length === 0
  ) {
    return { _tag: "latestReading", type: series.type };
  }
  return { _tag: "latestData", type: series.type };
};

/** The lead's points, as `(start, value)`: its first visible series', or else its first visible formula's. */
export const leadPoints = (data: CardRunData): ReadonlyArray<CardFormulaPoint> => {
  const series = data.series.find((candidate) => !candidate.hidden);
  if (series !== undefined) return series.points.map(({ start, value }) => ({ start, value }));
  return data.formulas.find((candidate) => !candidate.hidden)?.points ?? [];
};

/** The dates whose buckets a search's runs end with, in order: now's, then 7 buckets before each. */
export const headlineSearchEnds = (
  spec: CardSpec,
  now: number,
  calendar: CardCalendar,
): Array<number> => {
  const grain = headlineGrain(spec);
  const ends = [now];
  while (ends.length < headlineSearchRounds) {
    ends.push(bucketStart(calendar, grain, sparklineBuckets, ends.at(-1)!));
  }
  return ends;
};
