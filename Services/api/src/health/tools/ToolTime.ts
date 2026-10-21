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

const hourMillis = 60 * 60 * 1000;

/** When the hour `millis` falls in starts in `zone`: its local hour, in half-hour zones too. */
export const startOfHour = (millis: number, zone: DateTime.TimeZone): number => {
  const local = millis + DateTime.zonedOffset(zoned(millis, zone));
  return millis - (((local % hourMillis) + hourMillis) % hourMillis);
};

/** When the month `millis` falls in starts in `zone`, moved by `months` months. */
const startOfMonth = (millis: number, zone: DateTime.TimeZone, months = 0): number =>
  DateTime.toEpochMillis(
    DateTime.startOf(
      DateTime.add(DateTime.startOf(zoned(millis, zone), "month"), { months }),
      "day",
    ),
  );

/** The start of a `YYYY-MM-DD` day in `zone`. The toolkit's schema has checked the day exists. */
export const startOfLocalDay = (day: string, zone: DateTime.TimeZone): number => {
  const [year, month, date] = day.split("-").map(Number) as [number, number, number];
  // Noon is never skipped by a change of offset, unlike midnight in some zones.
  const noon = DateTime.makeZonedUnsafe(
    { year, month, day: date, hour: 12 },
    { timeZone: zone, adjustForTimeZone: true },
  );
  return startOfDay(DateTime.toEpochMillis(noon), zone);
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
 * 7-day weeks, and Y the 12 calendar months ending with its month, in months.
 */
export const toolPeriod = (
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
