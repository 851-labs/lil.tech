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
