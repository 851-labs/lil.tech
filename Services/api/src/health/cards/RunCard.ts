import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { latestSample } from "../tools/HealthQueries.ts";
import { localDate, localTime, startOfLocalDay, toolDate } from "../tools/ToolTime.ts";
import {
  type CardCalendar,
  type CardGrain,
  type CardWeekday,
  cardCalendar,
} from "./CardCalendar.ts";
import {
  CardRun,
  type CardRunData,
  type CardSummary,
  headlineGrain,
  headlineLookup,
  headlineOpeningDates,
  headlineSearchEnds,
  leadPoints,
} from "./CardEngine.ts";
import { fetchCardData, fetchCardWindow, latestDataStart } from "./CardQueries.ts";
import type {
  CardAggregation,
  CardBucket,
  CardFormulaKind,
  CardRange,
  CardSpec,
} from "./CardSpec.ts";

// The server's card engine (851-3197, `docs/decisions/cards.md`, The server): a card spec run over
// one period of the user's store, for remote agents' `preview_card` and `get_card` (851-3215). It
// never feeds an app: apps compute their cards from their own data. `runCard` is the engine;
// `cardData` is a tool's call of it (a day, a time zone and a first weekday as the tools take
// them); `cardHeadline` is a Summary row's value.

/** A card's data as the tools give it (`docs/decisions/cards.md`, Inputs and outputs). */
export interface CardData {
  /** The range it was run for, or null for a headline's buckets. */
  readonly range: CardRange | null;
  /** The period's first and last days, `YYYY-MM-DD`. */
  readonly start: string;
  readonly end: string;
  readonly timeZone: string;
  readonly firstWeekday: CardWeekday;
  /** The spec's bucket, and what each point covers once `auto` is resolved. */
  readonly bucket: CardBucket;
  readonly grain: CardGrain;
  readonly series: ReadonlyArray<{
    readonly id: string;
    readonly label: string;
    readonly type: string;
    readonly aggregation: CardAggregation;
    /** The series' value unit: its type's catalog unit, or `count` for a count. */
    readonly unit: string;
    readonly hidden: boolean;
    /** One a bucket with a value, in order. */
    readonly points: ReadonlyArray<{
      /** The bucket's start, local with its offset (a night's is its day's midnight). */
      readonly start: string;
      readonly value: number;
      readonly minimum: number;
      readonly maximum: number;
      /** Null for totals. */
      readonly readings: number | null;
    }>;
  }>;
  readonly formulas: ReadonlyArray<{
    readonly id: string;
    readonly kind: CardFormulaKind;
    /** Null unless the spec gives one: the apps choose what to call a formula without one. */
    readonly label: string | null;
    readonly unit: string;
    readonly hidden: boolean;
    readonly points: ReadonlyArray<{ readonly start: string; readonly value: number }>;
  }>;
  /** What the page's header shows; null when the period has no data (No Data). */
  readonly summary: CardSummary | null;
  /** The goal's value, in the lead's value unit. */
  readonly goal: number | null;
}

/** A run's data from the store: its windows' nights and workouts first, then its readings. */
const fetchRun = (sql: StoreSql, run: CardRun, now: number): CardRunData => {
  const windowed =
    run.windowFetches.length === 0
      ? run
      : run.windowed(run.windowFetches.map((fetch) => fetchCardWindow(sql, fetch)));
  return windowed.compute(
    windowed.fetches.map((fetch) => fetchCardData(sql, fetch, now, run.calendar)),
  );
};

/** A run's data as the tools write it: times local, with their offset, in the calendar's zone. */
export const cardDataJson = (
  data: CardRunData,
  spec: CardSpec,
  calendar: CardCalendar,
): CardData => {
  const { zone } = calendar;
  return {
    range: data.range,
    start: localDate(data.interval.start, zone),
    // The period ends at a midnight (or an hour), so its last moment is on its last day.
    end: localDate(data.interval.end - 1, zone),
    timeZone: calendar.timeZone,
    firstWeekday: calendar.firstWeekday,
    bucket: spec.bucket,
    grain: data.grain,
    series: data.series.map((series) => ({
      ...series,
      points: series.points.map((point) => ({ ...point, start: localTime(point.start, zone) })),
    })),
    formulas: data.formulas.map((formula) => ({
      ...formula,
      points: formula.points.map((point) => ({
        start: localTime(point.start, zone),
        value: point.value,
      })),
    })),
    summary: data.summary,
    goal: data.goal,
  };
};

/**
 * A canonical card spec run over the period of `range` containing `date`, from the user's store
 * (the Swift `HealthDatabase.cardData(_:range:date:now:calendar:)`): the entry point the cards'
 * conformance cases (851-3198) and the cards' tools (851-3215) call. `now` places 6M's periods and
 * picks the statistics source, as on the Mac. Times are Unix milliseconds.
 */
export const runCard = (
  sql: StoreSql,
  spec: CardSpec,
  range: CardRange,
  date: number,
  calendar: CardCalendar,
  now: number,
): CardData =>
  cardDataJson(
    fetchRun(sql, CardRun.forRange(spec, range, date, now, calendar), now),
    spec,
    calendar,
  );

/**
 * A card run as a tool asks for it: over `range` (default the spec's own) for the period containing
 * `date` (`YYYY-MM-DD` in the time zone; by default the card's opening date, `cardOpeningDate`,
 * or today without one), in `timeZone` (an IANA name, default UTC) with weeks from
 * `firstWeekday` (default Monday). An unknown time zone, or a date the tools don't take
 * (`toolDate`), is a `HealthToolError`.
 */
export const cardData = Effect.fn("cardData")(function* (
  sql: StoreSql,
  spec: CardSpec,
  input: {
    readonly range?: CardRange | undefined;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
    readonly firstWeekday?: CardWeekday | undefined;
  },
) {
  const calendar = yield* cardCalendar(input.timeZone, input.firstWeekday);
  const now = yield* Clock.currentTimeMillis;
  const day = yield* toolDate(input.date);
  const range = input.range ?? spec.range;
  // Without a date, the period the card's page opens on, as the apps' pages do (851-3987).
  const date =
    day === undefined
      ? (cardOpeningDate(sql, spec, range, calendar, now) ?? now)
      : startOfLocalDay(day, calendar.zone);
  return runCard(sql, spec, range, date, calendar, now);
});

/** What a card's Summary row shows: the lead's latest value, and the buckets ending on it. */
export interface CardHeadline {
  readonly value: number;
  /** The reading's start, or the bucket's, local with its offset. */
  readonly date: string;
  /** `reading`: a moment, shown as the reading's time. `bucket`: dated by `data.grain`. */
  readonly kind: "reading" | "bucket";
  /** The sparkline's run: the 7 buckets ending on it. */
  readonly data: CardData;
}

/**
 * What a card's Summary row shows (the Swift `HealthDatabase.cardHeadline`), from data started by
 * `now`; null for No Data. Found by `headlineLookup`: the lead type's latest reading, the bucket of
 * its latest data, or runs of 7 buckets back from now's, 8 times.
 */
export const cardHeadline = (
  sql: StoreSql,
  spec: CardSpec,
  calendar: CardCalendar,
  now: number,
): CardHeadline | null => {
  const run = (date: number) => fetchRun(sql, CardRun.forHeadline(spec, date, calendar), now);
  const json = (data: CardRunData) => cardDataJson(data, spec, calendar);
  const latestBucket = (data: CardRunData): CardHeadline | null => {
    const point = leadPoints(data).at(-1);
    return point === undefined
      ? null
      : {
          value: point.value,
          date: localTime(point.start, calendar.zone),
          kind: "bucket",
          data: json(data),
        };
  };
  const lookup = headlineLookup(spec);
  switch (lookup?._tag) {
    case undefined:
      return null;
    case "latestReading": {
      const sample = latestSample(sql, lookup.type, now);
      if (sample === null || sample.value === null) return null;
      return {
        value: sample.value,
        date: localTime(sample.startDate, calendar.zone),
        kind: "reading",
        data: json(run(sample.startDate)),
      };
    }
    case "latestData": {
      const start = latestDataStart(sql, lookup.type, now);
      return start === null ? null : latestBucket(run(start));
    }
    case "search": {
      const found = searchLatestBucket(sql, spec, calendar, now);
      return found === null ? null : latestBucket(found.data);
    }
  }
};

/**
 * A headline's search: runs of 7 buckets ending with now's, then 7 earlier each time, until one has
 * a lead value. Its latest point and the run it's in, or null for No Data.
 */
const searchLatestBucket = (
  sql: StoreSql,
  spec: CardSpec,
  calendar: CardCalendar,
  now: number,
): { readonly start: number; readonly data: CardRunData } | null => {
  for (const end of headlineSearchEnds(spec, now, calendar)) {
    const data = fetchRun(sql, CardRun.forHeadline(spec, end, calendar), now);
    const point = leadPoints(data).at(-1);
    if (point !== undefined) return { start: point.start, data };
  }
  return null;
};

/**
 * When the period of `range` a card's page opens on is from (the Swift
 * `HealthDatabase.cardOpeningDate`, 851-3987): its headline's, as its Summary row finds it, so the
 * tools run a card without a `date` over the period the apps open it on. Without a window, filter
 * or formula, the lead type's latest data (`latestDataStart`), which the headline's run ends on.
 * With one, that may have none of the card's readings, so it's the headline's bucket, from its
 * search, and when that bucket straddles two periods, the later one if it has the bucket's point
 * (`headlineOpeningDates`). Null for No Data: the current period.
 */
export const cardOpeningDate = (
  sql: StoreSql,
  spec: CardSpec,
  range: CardRange,
  calendar: CardCalendar,
  now: number,
): number | null => {
  const lookup = headlineLookup(spec);
  switch (lookup?._tag) {
    case undefined:
      return null;
    case "latestReading":
    case "latestData":
      return latestDataStart(sql, lookup.type, now);
    case "search": {
      const found = searchLatestBucket(sql, spec, calendar, now);
      if (found === null) return null;
      const dates = headlineOpeningDates(found.start, headlineGrain(spec), range, calendar, now);
      for (const date of dates.slice(0, -1)) {
        const data = fetchRun(sql, CardRun.forRange(spec, range, date, now, calendar), now);
        if (leadPoints(data).some((point) => point.start === found.start)) return date;
      }
      return dates.at(-1)!;
    }
  }
};
