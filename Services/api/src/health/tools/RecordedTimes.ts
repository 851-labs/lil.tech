import { type DateTime, Predicate } from "effect";
import { metadataValue } from "../MetadataValues.ts";
import type { Metadata } from "../WorkoutMetadata.ts";
import { localTime, namedTimeZone } from "./ToolTime.ts";

// A record's recorded times (851-4177, `docs/decisions/health.md` › Recorded time zones): every
// time a tool gives is in the call's `timeZone`, so times compare across records, and a record
// with a zone (`HKTimeZone`, a name `namedTimeZone` takes) adds that zone's name and the same
// instants on its clock. The Mac's tools give the same (`RecordedTimes` in `HealthTools`).

/**
 * A row's `HKTimeZone`, read in SQL for the tools that don't otherwise read a record's metadata, as
 * the cards' sleep records read it (`cardSleepRecords`): metadata that isn't JSON loses only the
 * zone, and a value that isn't a string isn't one (`RecordedZones.named`).
 */
export const recordedZoneSql =
  "CASE WHEN json_valid(metadata) THEN metadata ->> '$.HKTimeZone' END";

/** A record's zone and its start and end on that zone's clock; empty without a zone. */
export interface RecordedTimes {
  readonly recordedTimeZone?: string;
  readonly recordedStart?: string;
  readonly recordedEnd?: string;
}

/** A record of one time's zone and that time on its clock; empty without a zone. */
export interface RecordedTime {
  readonly recordedTimeZone?: string;
  readonly recordedTime?: string;
}

/**
 * The zones records were recorded in, each name looked up once (a lookup costs tens of
 * microseconds, and a page's records share a few names).
 */
export class RecordedZones {
  readonly #zones = new Map<string, DateTime.TimeZone.Named | undefined>();

  /** The zone named `name`, if it's one the tools' `timeZone` takes (`namedTimeZone`). */
  zone(name: string): DateTime.TimeZone.Named | undefined {
    if (!this.#zones.has(name)) this.#zones.set(name, namedTimeZone(name));
    return this.#zones.get(name);
  }

  /** The zone named `name`, as is, with `start` and `end` on its clock; empty if it isn't one. */
  named(name: unknown, start: number, end: number): RecordedTimes {
    const zone = Predicate.isString(name) ? this.zone(name) : undefined;
    return zone === undefined
      ? {}
      : {
          recordedTimeZone: name as string,
          recordedStart: localTime(start, zone),
          recordedEnd: localTime(end, zone),
        };
  }

  /** The recorded times of a record from `start` to `end` whose metadata is `metadata`. */
  times(metadata: Metadata | null | undefined, start: number, end: number): RecordedTimes {
    return this.named(metadataValue(metadata, "HKTimeZone"), start, end);
  }

  /** The zone named `name` (`named`), with `time` on its clock: a record of one time's. */
  namedAt(name: unknown, time: number): RecordedTime {
    const zone = Predicate.isString(name) ? this.zone(name) : undefined;
    return zone === undefined
      ? {}
      : { recordedTimeZone: name as string, recordedTime: localTime(time, zone) };
  }
}
