import { hourMillis } from "../tools/ToolTime.ts";
import { type CardCalendar, CardBucketer, type CardInterval, zoneOffset } from "./CardCalendar.ts";

// Nights from sleep records (`docs/decisions/cards.md`, Event windows › Nights): the Swift core's
// `CardNights`, which Sleep's page, its highlights and cards' sleep windows all group with, so the
// Mac, the iPhone and the server name the same nights. The `sleep` tool reads its nights here too.

/** One sleep analysis record (`HKCategoryTypeIdentifierSleepAnalysis`), as every engine reads it. */
export interface CardSleepRecord {
  /** Unix milliseconds. */
  readonly start: number;
  readonly end: number;
  /**
   * `HKCategoryValueSleepAnalysis`' raw value: In Bed 0, Asleep 1, Awake 2, Core 3, Deep 4, REM 5.
   * Other values aren't sleep the engine knows, and are left out.
   */
  readonly value: number;
  /** The source's bundle ID: a night uses one source. */
  readonly source: string;
}

export const sleepInBed = 0;
export const sleepAwake = 2;

/** Whether it's a value the engine knows (In Bed, Asleep, Awake, Core, Deep or REM). */
const isKnown = (record: CardSleepRecord) =>
  Number.isInteger(record.value) && record.value >= 0 && record.value <= 5;

/** Whether it's time asleep: Asleep, Core, Deep or REM. */
export const isAsleep = (record: CardSleepRecord) =>
  isKnown(record) && record.value !== sleepInBed && record.value !== sleepAwake;

const duration = (record: CardSleepRecord) => record.end - record.start;

/** How far before midnight a night can start: sleep from 6 PM counts toward the next day. */
export const nightStartOffset = 6 * hourMillis;

/** A gap this long between stretches of sleep starts a new session: a nap after the night. */
export const sessionGap = 3 * hourMillis;

/**
 * The latest a night's sleep can start, in hours from its day's midnight, to be a night's: noon.
 * Later is a day's sleep, which Sleep's highlights and cards leave out.
 */
export const latestBedtime = 12;

/** A night's sleep, named by the day it ends on, as Health does. */
export interface CardNight {
  /** The start of the day the night belongs to. */
  readonly day: number;
  /** The chosen source's records in its main session, by start: its stages, not In Bed. */
  readonly records: ReadonlyArray<CardSleepRecord>;
  /**
   * Time in bed, in milliseconds: every source's In Bed records that overlap the night, counted
   * once, wherever they start; without any, the night's span.
   */
  readonly inBed: number;
}

/** `F`: when sleep started, the start of its first record asleep. */
export const fallingAsleep = (night: CardNight): number | undefined =>
  night.records.find(isAsleep)?.start;

/** `W`: when sleep ended, the latest end among its records asleep. */
export const waking = (night: CardNight): number | undefined => {
  let latest: number | undefined;
  for (const record of night.records) {
    if (isAsleep(record) && (latest === undefined || record.end > latest)) latest = record.end;
  }
  return latest;
};

/** Its stretches asleep, by start: its records asleep, merged where they touch or overlap. */
export const asleepStretches = (night: CardNight): Array<{ start: number; end: number }> => {
  const stretches: Array<{ start: number; end: number }> = [];
  for (const record of night.records) {
    if (!isAsleep(record) || record.start >= record.end) continue;
    const last = stretches.at(-1);
    if (last !== undefined && record.start <= last.end) last.end = Math.max(last.end, record.end);
    else stretches.push({ start: record.start, end: record.end });
  }
  return stretches;
};

/**
 * Where `millis` goes in the night that started at `start`, in hours from `day`'s midnight, on the
 * local clock as it read when the night started: 11 PM the evening before is -1, 7:30 AM is 7.5.
 */
export const clockHours = (
  millis: number,
  day: number,
  start: number,
  calendar: CardCalendar,
): number => {
  const shift = zoneOffset(start, calendar.zone) - zoneOffset(day, calendar.zone);
  return (millis - day + shift) / hourMillis;
};

/**
 * A night's bedtime on the clock, in hours from its day's midnight (placed from its first record),
 * if it's a night's sleep rather than a day's: sleep that starts before noon. Undefined for a day's.
 */
export const nightBedtime = (night: CardNight, calendar: CardCalendar): number | undefined => {
  const asleepAt = fallingAsleep(night);
  if (asleepAt === undefined || night.records.length === 0) return undefined;
  const first = night.records.reduce((least, record) => Math.min(least, record.start), Infinity);
  const hours = clockHours(asleepAt, night.day, first, calendar);
  return hours < latestBedtime ? hours : undefined;
};

/**
 * The records the nights of `days` (local midnights, the first day's up to the day after the
 * last's) are made of: those that end after the first night can start and start before the day
 * after the last's can. In Bed records may start before it.
 */
export const nightRecordRange = (days: CardInterval): CardInterval => ({
  start: days.start - nightStartOffset,
  end: days.end - nightStartOffset,
});

const asleepTime = (records: ReadonlyArray<CardSleepRecord>) =>
  records.reduce((total, record) => total + (isAsleep(record) ? duration(record) : 0), 0);

/**
 * The session with the most sleep among `records`, splitting where sleep stops for `sessionGap` or
 * more. Of sessions with as much sleep, the first.
 */
const mainSession = (records: ReadonlyArray<CardSleepRecord>): ReadonlyArray<CardSleepRecord> => {
  const sessions: Array<Array<CardSleepRecord>> = [];
  let lastEnd: number | undefined;
  for (const record of [...records].sort((a, b) => a.start - b.start)) {
    const session = sessions.at(-1);
    if (lastEnd !== undefined && record.start - lastEnd < sessionGap && session !== undefined) {
      session.push(record);
    } else {
      sessions.push([record]);
    }
    lastEnd = Math.max(lastEnd ?? record.end, record.end);
  }
  let best: ReadonlyArray<CardSleepRecord> = sessions[0] ?? [];
  let bestAsleep = asleepTime(best);
  for (const session of sessions.slice(1)) {
    const asleep = asleepTime(session);
    if (asleep > bestAsleep) {
      best = session;
      bestAsleep = asleep;
    }
  }
  return best;
};

/** The total time `records` cover, counting overlaps once. */
const union = (records: ReadonlyArray<CardSleepRecord>) => {
  let total = 0;
  let open: { start: number; end: number } | undefined;
  for (const record of [...records].sort((a, b) => a.start - b.start)) {
    if (open !== undefined && record.start <= open.end) {
      open.end = Math.max(open.end, record.end);
    } else {
      if (open !== undefined) total += open.end - open.start;
      open = { start: record.start, end: record.end };
    }
  }
  return open === undefined ? total : total + open.end - open.start;
};

/**
 * The nights of `days`, oldest first, leaving out days without sleep, from `records` (by start, as
 * `nightRecordRange` gives them). Nights' and days' sleep both: Sleep's page shows a day's, which
 * `nightBedtime` tells apart.
 * - **The day:** a record belongs to the day `nightStartOffset` after its start, when it starts in
 *   the range.
 * - **Source:** each night uses one source, the one with the most time asleep that day, ties to
 *   the bundle ID that sorts first, so overlapping sources don't add up.
 * - **The night:** that source's session with the most sleep. Naps on the same day aren't part of
 *   it.
 * - **In bed:** every source's In Bed records that overlap the night, counted once, wherever they
 *   start. Without any, the night's span.
 */
export const cardNights = (
  records: ReadonlyArray<CardSleepRecord>,
  days: CardInterval,
  calendar: CardCalendar,
): Array<CardNight> => {
  const range = nightRecordRange(days);
  const known = records.filter(isKnown);
  const inBedRecords = known.filter((record) => record.value === sleepInBed);
  // Each day's bounds once, as records come by start (851-2906).
  const bucketer = new CardBucketer(calendar, "day");
  const byDay = new Map<number, Array<CardSleepRecord>>();
  for (const record of known) {
    if (record.value === sleepInBed || record.start < range.start || record.start >= range.end) {
      continue;
    }
    const day = bucketer.startOf(record.start + nightStartOffset);
    const night = byDay.get(day);
    if (night === undefined) byDay.set(day, [record]);
    else night.push(record);
  }
  const nights: Array<CardNight> = [];
  for (const [day, dayRecords] of byDay) {
    // Milliseconds, so a tie between two sources' time asleep is exact on every engine.
    const asleepBySource = new Map<string, number>();
    for (const record of dayRecords) {
      if (isAsleep(record)) {
        asleepBySource.set(
          record.source,
          (asleepBySource.get(record.source) ?? 0) + duration(record),
        );
      }
    }
    let source: string | undefined;
    let most = -1;
    for (const [candidate, time] of asleepBySource) {
      if (time > most || (time === most && candidate < source!)) {
        source = candidate;
        most = time;
      }
    }
    if (source === undefined) continue;
    const session = mainSession(dayRecords.filter((record) => record.source === source));
    if (session.length === 0) continue;
    let start = Infinity;
    let end = -Infinity;
    for (const record of session) {
      start = Math.min(start, record.start);
      end = Math.max(end, record.end);
    }
    const inBed = union(inBedRecords.filter((record) => record.start < end && record.end > start));
    nights.push({
      day,
      records: [...session].sort((a, b) => a.start - b.start),
      inBed: inBed > 0 ? inBed : end - start,
    });
  }
  return nights.sort((a, b) => a.day - b.day);
};
