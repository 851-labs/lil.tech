import { DateTime, Effect } from "effect";
import {
  hourMillis,
  startOfDay,
  startOfHour,
  startOfMonth,
  toolTimeZone,
} from "../tools/ToolTime.ts";
import type { CardBucket, CardRange } from "./CardSpec.ts";

// Periods and buckets for the server's card engine (851-3197, `docs/decisions/cards.md`, Bucket
// and range): the Swift core's `CardPeriods`, with Foundation's calendar replaced by the call's
// time zone and first weekday. Times are Unix milliseconds. Time-zone math costs tens of
// microseconds a call (851-2906), so it's done once per bucket, never per reading: `CardBucketer`
// answers from the last bucket until a time leaves it.

/** The days a week may start on, as the tools name them. */
export const cardWeekdays = [
  "sunday",
  "monday",
  "tuesday",
  "wednesday",
  "thursday",
  "friday",
  "saturday",
] as const;
export type CardWeekday = (typeof cardWeekdays)[number];

/** The first weekday the server uses when a call doesn't give one. */
export const defaultCardWeekday: CardWeekday = "monday";

/**
 * The engine's calendar: a time zone and the day weeks start on, as Foundation's `Calendar` is for
 * the Mac's and the iPhone's engines.
 */
export interface CardCalendar {
  readonly zone: DateTime.TimeZone;
  /** The zone's name, as the call gave it. */
  readonly timeZone: string;
  readonly firstWeekday: CardWeekday;
}

/**
 * The calendar a call asked for: its time zone (an IANA name, default UTC) and first weekday
 * (default Monday). An unknown time zone is the call's error, as for the Health tools.
 */
export const cardCalendar = Effect.fnUntraced(function* (
  timeZone: string | undefined,
  firstWeekday: CardWeekday | undefined,
) {
  const { zone, name } = yield* toolTimeZone(timeZone);
  const calendar: CardCalendar = {
    zone,
    timeZone: name,
    firstWeekday: firstWeekday ?? defaultCardWeekday,
  };
  return calendar;
});

/** What one point covers, once `auto` is resolved: a clock hour, or a calendar day, week or month. */
export type CardGrain = "hour" | "day" | "week" | "month";

/** What each point covers at a range, as Metric Detail: an hour (D), a day (W, M), a week (6M), a month (Y). */
export const rangeGrain = (range: CardRange): CardGrain => {
  switch (range) {
    case "D":
      return "hour";
    case "W":
    case "M":
      return "day";
    case "6M":
      return "week";
    case "Y":
      return "month";
  }
};

/**
 * What each point covers at `range`: the range's grain for `auto`, else the bucket's own. A
 * `night` bucket is its night's day for series without a sleep window.
 */
export const bucketGrain = (bucket: CardBucket, range: CardRange): CardGrain => {
  switch (bucket) {
    case "auto":
      return rangeGrain(range);
    case "hour":
      return "hour";
    case "day":
    case "night":
      return "day";
    case "week":
      return "week";
    case "month":
      return "month";
  }
};

const zoned = (millis: number, zone: DateTime.TimeZone) =>
  DateTime.makeZonedUnsafe(millis, { timeZone: zone });

/** The zone's offset from UTC at `millis`, in milliseconds. */
export const zoneOffset = (millis: number, zone: DateTime.TimeZone): number =>
  DateTime.zonedOffset(zoned(millis, zone));

/** When the year `millis` falls in starts in `zone`, moved by `years` years. */
const startOfYear = (millis: number, zone: DateTime.TimeZone, years = 0): number =>
  DateTime.toEpochMillis(
    DateTime.startOf(DateTime.add(DateTime.startOf(zoned(millis, zone), "year"), { years }), "day"),
  );

/** When the week `millis` falls in starts: the calendar's first weekday, at midnight. */
const startOfWeek = (millis: number, calendar: CardCalendar): number => {
  const day = startOfDay(millis, calendar.zone);
  const weekday = DateTime.getPart(zoned(day, calendar.zone), "weekDay");
  const back = (weekday - cardWeekdays.indexOf(calendar.firstWeekday) + 7) % 7;
  return back === 0 ? day : startOfDay(day, calendar.zone, -back);
};

/** When the bucket of `grain` containing `millis` starts (Foundation's `dateInterval(of:for:)`). */
export const grainStart = (calendar: CardCalendar, grain: CardGrain, millis: number): number => {
  switch (grain) {
    case "hour":
      return startOfHour(millis, calendar.zone);
    case "day":
      return startOfDay(millis, calendar.zone);
    case "week":
      return startOfWeek(millis, calendar);
    case "month":
      return startOfMonth(millis, calendar.zone);
  }
};

/**
 * The start of the bucket `count` buckets after the one starting at `start` (negative goes back),
 * as Foundation adds them: hours by elapsed time, days, weeks and months on the clock.
 */
export const addGrains = (
  calendar: CardCalendar,
  grain: CardGrain,
  start: number,
  count: number,
): number => {
  switch (grain) {
    case "hour":
      return startOfHour(start + count * hourMillis, calendar.zone);
    case "day":
      return startOfDay(start, calendar.zone, count);
    case "week":
      return startOfWeek(startOfDay(start, calendar.zone, 7 * count), calendar);
    case "month":
      return startOfMonth(start, calendar.zone, count);
  }
};

/** When the bucket starting at `start` ends: the next one's start. */
export const grainEnd = (calendar: CardCalendar, grain: CardGrain, start: number): number => {
  const end = addGrains(calendar, grain, start, 1);
  // An hour that a change of offset cuts short still moves on.
  return end > start ? end : start + hourMillis;
};

/** The start of the bucket `count` buckets before the one containing `millis`. */
export const bucketStart = (
  calendar: CardCalendar,
  grain: CardGrain,
  count: number,
  millis: number,
): number => {
  const start = grainStart(calendar, grain, millis);
  return count > 0 ? addGrains(calendar, grain, start, -count) : start;
};

/** The starts of the buckets from the one containing `from` up to `to`, in order. */
export const bucketStarts = (
  calendar: CardCalendar,
  grain: CardGrain,
  from: number,
  to: number,
): Array<number> => {
  const starts: Array<number> = [];
  let start = grainStart(calendar, grain, from);
  while (start < to) {
    starts.push(start);
    start = grainEnd(calendar, grain, start);
  }
  return starts;
};

/**
 * Finds the bucket a time falls in, working out a bucket's bounds only when a time leaves the last
 * one, so a year of readings costs time-zone math per bucket rather than per reading (the Swift
 * core's `CardBucketer`).
 */
export class CardBucketer {
  readonly calendar: CardCalendar;
  readonly grain: CardGrain;
  private start = Number.NaN;
  private end = Number.NaN;

  // Not parameter properties, which Node's type stripping can't run.
  constructor(calendar: CardCalendar, grain: CardGrain) {
    this.calendar = calendar;
    this.grain = grain;
  }

  /** The start of the bucket containing `millis`. */
  startOf(millis: number): number {
    if (!(millis >= this.start && millis < this.end)) {
      this.start = grainStart(this.calendar, this.grain, millis);
      this.end = grainEnd(this.calendar, this.grain, this.start);
    }
    return this.start;
  }
}

/** A period, from `start` up to `end`, in Unix milliseconds. */
export interface CardInterval {
  readonly start: number;
  readonly end: number;
}

/** The calendar unit a range's periods are made of (6M's are months, six at a time). */
const rangeUnit = (range: CardRange): "day" | "week" | "month" | "year" => {
  switch (range) {
    case "D":
      return "day";
    case "W":
      return "week";
    case "M":
    case "6M":
      return "month";
    case "Y":
      return "year";
  }
};

const unitStart = (calendar: CardCalendar, unit: ReturnType<typeof rangeUnit>, millis: number) =>
  unit === "year" ? startOfYear(millis, calendar.zone) : grainStart(calendar, unit, millis);

const addUnits = (
  calendar: CardCalendar,
  unit: ReturnType<typeof rangeUnit>,
  start: number,
  count: number,
) =>
  unit === "year"
    ? startOfYear(start, calendar.zone, count)
    : addGrains(calendar, unit, start, count);

/**
 * The period `offset` periods from the one containing `now` (0 is the current one, -1 the one
 * before): a calendar day, week, month or year, or the six calendar months ending with the date's
 * (`CardRange.interval(offset:now:calendar:)`).
 */
export const rangeInterval = (
  calendar: CardCalendar,
  range: CardRange,
  offset: number,
  now: number,
): CardInterval => {
  const unit = rangeUnit(range);
  const shifted = (count: number): CardInterval => {
    const start = unitStart(
      calendar,
      unit,
      addUnits(calendar, unit, unitStart(calendar, unit, now), count),
    );
    return { start, end: addUnits(calendar, unit, start, 1) };
  };
  if (range !== "6M") return shifted(offset);
  // The six months ending with the current month, then the six before them.
  const month = shifted(offset * 6);
  return { start: startOfMonth(month.start, calendar.zone, -5), end: month.end };
};

/** A day's number since the epoch on the local calendar, for counting days between two. */
const localDayNumber = (millis: number, zone: DateTime.TimeZone) => {
  const { year, month, day } = DateTime.toParts(zoned(millis, zone));
  return Date.UTC(year, month - 1, day) / 86_400_000;
};

/**
 * How many periods from the one containing `now` the one containing `date` is: 0 for the current
 * one, -1 for the one before, positive for one after (`CardRange.offset(containing:now:calendar:)`).
 */
export const rangeOffset = (
  calendar: CardCalendar,
  range: CardRange,
  date: number,
  now: number,
): number => {
  const { zone } = calendar;
  const unit = rangeUnit(range);
  const from = unitStart(calendar, unit, now);
  const to = unitStart(calendar, unit, date);
  const months = () => {
    const a = DateTime.toParts(zoned(from, zone));
    const b = DateTime.toParts(zoned(to, zone));
    return (b.year - a.year) * 12 + (b.month - a.month);
  };
  let offset: number;
  switch (range) {
    case "D":
      offset = localDayNumber(to, zone) - localDayNumber(from, zone);
      break;
    case "W":
      offset = Math.trunc((localDayNumber(to, zone) - localDayNumber(from, zone)) / 7);
      break;
    case "M":
      offset = months();
      break;
    case "Y":
      offset =
        DateTime.getPart(zoned(to, zone), "year") - DateTime.getPart(zoned(from, zone), "year");
      break;
    case "6M":
      // Six months ending with the current month's: months -5 to 0 are 0, -11 to -6 are -1.
      offset = Math.ceil(months() / 6);
      break;
  }
  // Settled against the intervals themselves, which are what the page shows.
  for (let round = 0; round < 4; round++) {
    const interval = rangeInterval(calendar, range, offset, now);
    if (date < interval.start) offset -= 1;
    else if (date >= interval.end) offset += 1;
    else break;
  }
  return offset;
};

/**
 * The period of `range` containing `date`: 6M's are the six months ending with `now`'s, then the
 * six before them.
 */
export const rangeIntervalContaining = (
  calendar: CardCalendar,
  range: CardRange,
  date: number,
  now: number,
): CardInterval => rangeInterval(calendar, range, rangeOffset(calendar, range, date, now), now);

// MARK: - Times of day

const dayMillis = 86_400_000;

/**
 * The next time after `after`, up to `limit`, when the zone's offset changes, or undefined. Offsets
 * are compared a day apart, then the change is found to the millisecond: JavaScript has no list of
 * a zone's transitions, and a zone changes at most once a day.
 */
const nextTransition = (after: number, limit: number, zone: DateTime.TimeZone) => {
  const offset = zoneOffset(after, zone);
  let low = after;
  while (low < limit) {
    let high = Math.min(low + dayMillis, limit);
    if (zoneOffset(high, zone) !== offset) {
      while (high - low > 1) {
        const middle = Math.floor((low + high) / 2);
        if (zoneOffset(middle, zone) === offset) low = middle;
        else high = middle;
      }
      return high;
    }
    low = high;
  }
  return undefined;
};

const floorTo = (value: number, divisor: number) => Math.floor(value / divisor) * divisor;

/** A time on the 24-hour clock (`07:30`), in milliseconds since midnight. */
const clockMillis = (time: string) =>
  (Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5))) * 60_000;

/**
 * A `timeOfDay` window's stretches that overlap `span` (Unix milliseconds, `[from, to)`), in order,
 * clipped to it: each local day's `[from, to)` on its clock, or `[from, to + 1 day)` crossing
 * midnight (`CardTimeOfDay.stretches(in:timeZone:)`).
 *
 * Placed with the zone's offsets rather than per reading: between two of its transitions the clock
 * is the moment plus a fixed offset, so each stretch is exact there, and a day of a daylight saving
 * change gets the clock's hours, as the rule has them: a skipped hour holds nothing, and a repeated
 * hour counts both times.
 */
export const timeOfDayStretches = (
  window: { readonly from: string; readonly to: string },
  span: CardInterval,
  zone: DateTime.TimeZone,
): Array<{ start: number; end: number }> => {
  const from = clockMillis(window.from);
  const to = clockMillis(window.to);
  const stretches: Array<{ start: number; end: number }> = [];
  const append = (start: number, end: number) => {
    if (start >= end) return;
    const last = stretches.at(-1);
    if (last !== undefined && last.end >= start) last.end = Math.max(last.end, end);
    else stretches.push({ start, end });
  };
  let segmentStart = span.start;
  while (segmentStart < span.end) {
    const offset = zoneOffset(segmentStart, zone);
    const transition = nextTransition(segmentStart, span.end, zone);
    const segmentEnd = Math.min(
      transition === undefined ? Number.POSITIVE_INFINITY : Math.max(transition, segmentStart + 1),
      span.end,
    );
    // The segment on the local clock, and each local day that can reach it.
    const localStart = segmentStart + offset;
    const localEnd = segmentEnd + offset;
    for (
      let dayStart = floorTo(localStart, dayMillis) - dayMillis;
      dayStart < localEnd;
      dayStart += dayMillis
    ) {
      const start = dayStart + from;
      const end = from < to ? dayStart + to : dayStart + dayMillis + to;
      append(Math.max(start, localStart) - offset, Math.min(end, localEnd) - offset);
    }
    segmentStart = segmentEnd;
  }
  return stretches;
};
