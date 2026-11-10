import { DateTime, Effect, Option } from "effect";
import { HealthToolError } from "./HealthToolkit.ts";

// Days and local times for the Health tools, in the time zone a call asks for. Outputs give times
// as `LocalTime` (`2026-10-20T08:15:00+01:00`: to the second, rounded down, with the offset,
// `+00:00` for UTC) and days as `YYYY-MM-DD`, so both MCP servers format them alike.

/** The time zone the remote server uses when a call doesn't give one. */
export const defaultToolTimeZone = "UTC";

/** An IANA name's shape: no UTC offsets such as `+01:00`, which `Intl` would also accept. */
const ianaName = /^[A-Za-z][A-Za-z0-9_+-]*(?:\/[A-Za-z0-9_+-]+)*$/;

/**
 * The time zone a call asked for, or UTC, with the name outputs give: the one asked for, as is,
 * so both servers echo the same string (`Intl` would turn some aliases into their canonical
 * names). Anything but an IANA name in its proper case is the call's error.
 */
export const toolTimeZone = (requested: string | undefined) => {
  const name = requested ?? defaultToolTimeZone;
  const zone = ianaName.test(name) ? DateTime.zoneMakeNamed(name) : Option.none();
  return Option.match(zone, {
    onNone: () =>
      Effect.fail(
        new HealthToolError({
          message: `Unknown time zone: ${name}. Use an IANA name, e.g. Europe/London.`,
        }),
      ),
    onSome: (zone) =>
      zone.id !== name && zone.id.toLowerCase() === name.toLowerCase()
        ? Effect.fail(
            new HealthToolError({
              message: `Unknown time zone: ${name}. Did you mean ${zone.id}?`,
            }),
          )
        : Effect.succeed({ zone, name }),
  });
};

const zoned = (millis: number, zone: DateTime.TimeZone) =>
  DateTime.makeZonedUnsafe(millis, { timeZone: zone });

/** A Unix time in milliseconds as a `LocalTime` in `zone`. */
export const localTime = (millis: number, zone: DateTime.TimeZone): string =>
  DateTime.formatIsoOffset(zoned(millis, zone)).replace(/\.\d+(?=[+-])/, "");

/** The day a Unix time in milliseconds falls on in `zone`, as `YYYY-MM-DD`. */
export const localDate = (millis: number, zone: DateTime.TimeZone): string =>
  DateTime.formatIsoDate(zoned(millis, zone));

/** When the day `days` after the one `millis` falls on in `zone` starts (negative goes back). */
export const startOfDay = (millis: number, zone: DateTime.TimeZone, days = 0): number =>
  DateTime.toEpochMillis(
    DateTime.startOf(DateTime.add(DateTime.startOf(zoned(millis, zone), "day"), { days }), "day"),
  );

/**
 * `startOfDay` for many times, such as a query's rows (851-2906). Time-zone math costs tens of
 * microseconds a call, seconds for a year of samples, so it works out a day's start and end once
 * and answers from them until a time falls outside: once a day for times in order.
 */
export const dayStarts = (zone: DateTime.TimeZone): ((millis: number) => number) => {
  let start = Number.NaN;
  let next = Number.NaN;
  return (millis) => {
    // Days don't overlap, so every time from a day's start until the next day's is in it.
    if (!(millis >= start && millis < next)) {
      start = startOfDay(millis, zone);
      next = startOfDay(start, zone, 1);
    }
    return start;
  };
};

export const hourMillis = 60 * 60 * 1000;

/** When the hour `millis` falls in starts in `zone`: its local hour, in half-hour zones too. */
export const startOfHour = (millis: number, zone: DateTime.TimeZone): number => {
  const local = millis + DateTime.zonedOffset(zoned(millis, zone));
  return millis - (((local % hourMillis) + hourMillis) % hourMillis);
};

/** When the month `millis` falls in starts in `zone`, moved by `months` months. */
export const startOfMonth = (millis: number, zone: DateTime.TimeZone, months = 0): number =>
  DateTime.toEpochMillis(
    DateTime.startOf(
      DateTime.add(DateTime.startOf(zoned(millis, zone), "month"), { months }),
      "day",
    ),
  );

/**
 * The start of a `YYYY-MM-DD` day in `zone`. A day that doesn't exist (2026-02-30) rolls over
 * into the next month, as Foundation's calendars do.
 */
export const startOfLocalDay = (day: string, zone: DateTime.TimeZone): number => {
  const [year, month, date] = day.split("-").map(Number) as [number, number, number];
  // Noon is never skipped by a change of offset, unlike midnight in some zones.
  const noon = DateTime.makeZonedUnsafe(
    { year, month, day: date, hour: 12 },
    { timeZone: zone, adjustForTimeZone: true },
  );
  return startOfDay(DateTime.toEpochMillis(noon), zone);
};

/**
 * The years the tools take a `date` in (851-4044). No Health data is older than 2000, and the
 * servers' time zones only agree since the 1970s: before then, Node's and Foundation's time zone
 * data can disagree on a zone's offset (zones merged in the database, offsets with seconds). Before
 * 1583 Foundation's Gregorian calendar is Julian, and it has no year 0, so the Mac and this server
 * would answer differently. Up to 2999, so a period's end never has a fifth digit.
 */
export const toolYears = { first: 2000, last: 2999 } as const;

/**
 * What's wrong with a `date`, in the Mac's words (`ToolTime.day`), or undefined for a day the tools
 * take: one that exists, written `YYYY-MM-DD` (not 2026-02-31 or 2026-2-3), in `toolYears`. The
 * year is checked first, so both servers give the same message for 1900-02-29.
 */
const dateProblem = (text: string): string | undefined => {
  const invalid = `Invalid date: ${text}. Use a day that exists, as YYYY-MM-DD.`;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return invalid;
  const year = Number(text.slice(0, 4));
  if (year < toolYears.first || year > toolYears.last) {
    return `Invalid date: ${text}. Use a day from ${toolYears.first}-01-01 to ${toolYears.last}-12-31.`;
  }
  // A day that doesn't exist (2026-02-31) is refused, or rolls over into another, which reads back
  // as another day.
  const day = DateTime.make(`${text}T00:00:00Z`);
  return Option.exists(day, (day) => DateTime.formatIsoDate(day) === text) ? undefined : invalid;
};

/**
 * Whether `text` is a day the tools take (`toolDate`): the access logs keep a call's `date` only
 * when it is, so they never keep text an agent sent in its place.
 */
export const isLocalDay = (text: string) => dateProblem(text) === undefined;

/**
 * A call's `date`, which must be a day the tools take (`dateProblem`), or the tool's error, in the
 * Mac's words (`ToolTime.day`). The input schemas take any string, so both servers refuse one
 * alike, for the Health tools (851-4034) and the card tools (851-4044). `toolPeriod` and
 * `cardData` check their date with it.
 */
export const toolDate = (date: string | undefined) => {
  const problem = date === undefined ? undefined : dateProblem(date);
  return problem === undefined
    ? Effect.succeed(date)
    : Effect.fail(new HealthToolError({ message: problem }));
};

/** A tool's range: Health's D, W, M, 6M or Y. */
export type ToolRange = "D" | "W" | "M" | "6M" | "Y";

/**
 * The period a call asked for (as the Mac's `ToolPeriod`): from `start` to `end` (exclusive, the
 * start of the day after the last), and its buckets' starts, oldest first. A bucket runs until
 * the next one starts, the last one until `end`.
 */
export interface ToolPeriod {
  readonly range: ToolRange;
  readonly start: number;
  readonly end: number;
  readonly buckets: ReadonlyArray<number>;
}

/**
 * The period ending on `date` (`YYYY-MM-DD` in `zone`), or today at `now` without one: D is that
 * day in hours, W and M the 7 and 30 days ending on it in days, 6M the 26 weeks ending on it in
 * 7-day weeks, and Y the 12 calendar months ending with its month, in months. A `date` that isn't
 * a day is the tool's error (`toolDate`), as the Mac's `ToolPeriod` throws it.
 */
export const toolPeriod = (
  range: ToolRange,
  date: string | undefined,
  now: number,
  zone: DateTime.TimeZone,
): Effect.Effect<ToolPeriod, HealthToolError> =>
  Effect.map(toolDate(date), (date) => periodEnding(range, date, now, zone));

const periodEnding = (
  range: ToolRange,
  date: string | undefined,
  now: number,
  zone: DateTime.TimeZone,
): ToolPeriod => {
  const lastDay = date === undefined ? startOfDay(now, zone) : startOfLocalDay(date, zone);
  const end = startOfDay(lastDay, zone, 1);
  const buckets: Array<number> = [];
  const add = (bucket: (index: number) => number) => {
    for (let index = 0; bucket(index) < end; index++) buckets.push(bucket(index));
  };
  switch (range) {
    case "D":
      add((index) => lastDay + index * hourMillis);
      break;
    case "W":
      add((index) => startOfDay(lastDay, zone, index - 6));
      break;
    case "M":
      add((index) => startOfDay(lastDay, zone, index - 29));
      break;
    case "6M":
      add((index) => startOfDay(lastDay, zone, index * 7 - 181));
      break;
    case "Y":
      add((index) => startOfMonth(lastDay, zone, index - 11));
      break;
  }
  return { range, start: buckets[0]!, end, buckets };
};

/** The index of the bucket of `period` that `millis` falls in, or undefined outside it. */
export const bucketIndex = (period: ToolPeriod, millis: number): number | undefined => {
  if (millis < period.start || millis >= period.end) return undefined;
  // The last bucket that starts by `millis`.
  let low = 0;
  let high = period.buckets.length - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (period.buckets[middle]! <= millis) low = middle;
    else high = middle - 1;
  }
  return low;
};
