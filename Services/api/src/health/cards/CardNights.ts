import { hourMillis, localDate, namedTimeZone, startOfLocalDay } from "../tools/ToolTime.ts";
import { type CardCalendar, CardBucketer, type CardInterval, zoneOffset } from "./CardCalendar.ts";

// Nights from sleep records (`docs/decisions/cards.md`, Event windows › Nights): the Swift core's
// `CardNights`, which Sleep's page, its highlights and cards' sleep windows all group with, so the
// Mac, the iPhone and the server name the same nights. The `sleep` tool reads its nights here too.
// A night follows the zone its records were recorded in (851-4175, cards.md › Recorded time
// zones), as Apple Health draws it: ported rule for rule from the Swift core (851-4174).

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
  /**
   * The name of the zone it was recorded in (`HKTimeZone`), when it's one the tools' `timeZone`
   * takes (`namedTimeZone`), else none. Its night follows it (`cardNights`).
   */
  readonly timeZone?: string;
}

/** Sleep analysis' HealthKit identifier. */
export const sleepAnalysisType = "HKCategoryTypeIdentifierSleepAnalysis";

/** `HKCategoryValueSleepAnalysis`' raw values: the stages the engine knows. */
export const sleepStages = { inBed: 0, asleep: 1, awake: 2, core: 3, deep: 4, rem: 5 } as const;
export type SleepStage = (typeof sleepStages)[keyof typeof sleepStages];

/** Whether it's a value the engine knows (In Bed, Asleep, Awake, Core, Deep or REM). */
const isKnown = (record: CardSleepRecord) =>
  Number.isInteger(record.value) &&
  record.value >= sleepStages.inBed &&
  record.value <= sleepStages.rem;

/** Whether it's time asleep: Asleep, Core, Deep or REM. */
export const isAsleep = (record: CardSleepRecord) =>
  isKnown(record) && record.value !== sleepStages.inBed && record.value !== sleepStages.awake;

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
  /**
   * The start of the day the night belongs to, in the engine's calendar: the calendar's day of the
   * date the night has on its own clock.
   */
  readonly day: number;
  /**
   * The name of the zone it was recorded in (`cardNights`), or none for the calendar's. Its date,
   * bedtime and clock are that zone's (`nightClock`).
   */
  readonly timeZone?: string;
  /** The chosen source's records in its main session, by start: its stages, not In Bed. */
  readonly records: ReadonlyArray<CardSleepRecord>;
  /** When its records start and end: the earliest start, and the latest end. */
  readonly start: number;
  readonly end: number;
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
 * A night's bedtime on its own clock (its zone's), in hours from its day's midnight there (placed
 * from its first record), if it's a night's sleep rather than a day's: sleep that starts before
 * noon. Undefined for a day's.
 */
export const nightBedtime = (night: CardNight, calendar: CardCalendar): number | undefined => {
  const asleepAt = fallingAsleep(night);
  if (asleepAt === undefined) return undefined;
  const clock = nightClock(night.day, night.timeZone, calendar);
  const hours = clockHours(asleepAt, clock.day, night.start, clock.calendar);
  return hours < latestBedtime ? hours : undefined;
};

/**
 * How far a day's midnight in another zone can be from the calendar's: 26 hours, from UTC−12 to
 * UTC+14. A night recorded in another zone starts up to that far outside the calendar's days.
 */
export const zoneReach = 26 * hourMillis;

/**
 * The records the nights of `days` (local midnights, the first day's up to the day after the
 * last's) are made of, in any zone: those that end after the first night can start and start
 * before the day after the last's can, `zoneReach` wider on each side. In Bed records may start
 * before it. Cards' sleep windows, the `sleep` tool and Sleep's page all fetch it, and
 * `cardNights` keeps the nights of `days`.
 */
export const nightRecordRange = (days: CardInterval): CardInterval => ({
  start: days.start - nightStartOffset - zoneReach,
  end: days.end - nightStartOffset + zoneReach,
});

/**
 * `calendar` in the zone named `timeZone`, or undefined for none or the calendar's own: the one
 * comparison that decides whether a night is on another clock, for placing its records and reading
 * its clock (the Swift core's `CardNights.zoned`).
 */
const zonedCalendar = (
  calendar: CardCalendar,
  timeZone: string | undefined,
): CardCalendar | undefined => {
  if (timeZone === undefined || timeZone === calendar.timeZone) return undefined;
  const zone = namedTimeZone(timeZone);
  return zone === undefined ? undefined : { ...calendar, zone, timeZone };
};

/**
 * The start of the day in `target` with the date `day` has in `source`. Through noon, so a zone
 * whose clocks skip midnight still has the day.
 */
const sameDate = (day: number, source: CardCalendar, target: CardCalendar): number =>
  startOfLocalDay(localDate(day, source.zone), target.zone);

/**
 * A night's clock: the calendar in its zone (`CardNight.timeZone`), and the midnight there that
 * starts its day's date. The calendar and `day` themselves for a night in none, or in the
 * calendar's.
 */
export const nightClock = (
  day: number,
  timeZone: string | undefined,
  calendar: CardCalendar,
): { readonly calendar: CardCalendar; readonly day: number } => {
  const zoned = zonedCalendar(calendar, timeZone);
  return zoned === undefined
    ? { calendar, day }
    : { calendar: zoned, day: sameDate(day, calendar, zoned) };
};

/** A record and its run's zone (`sleepRuns`). */
interface Placed {
  readonly record: CardSleepRecord;
  readonly timeZone: string | undefined;
}

/** A run of a source's records, by their indices, and its zone's name (`sleepRuns`). */
interface SleepRun {
  readonly indices: ReadonlyArray<number>;
  readonly timeZone: string | undefined;
}

/**
 * `records`' runs, by their indices: each source's records split where sleep stops for
 * `sessionGap` or more (as `mainSession` splits them), in absolute time, each taking the zone of
 * the last-ending of its records that have one, ties to the name that sorts first, so the
 * records' order never matters; none for a run without any, the calendar's. When no record has a
 * zone (as before 851-4175, or from apps that don't say), one run of them all.
 */
export const sleepRuns = (records: ReadonlyArray<CardSleepRecord>): Array<SleepRun> => {
  if (!records.some((record) => record.timeZone !== undefined)) {
    return [{ indices: records.map((_, index) => index), timeZone: undefined }];
  }
  const bySource = new Map<string, Array<number>>();
  records.forEach((record, index) => {
    const indices = bySource.get(record.source);
    if (indices === undefined) bySource.set(record.source, [index]);
    else indices.push(index);
  });
  const runs: Array<SleepRun> = [];
  for (const indices of bySource.values()) {
    let run: Array<number> = [];
    const close = () => {
      let zone: { end: number; name: string } | undefined;
      for (const index of run) {
        const { timeZone: own, end } = records[index]!;
        if (own === undefined) continue;
        if (zone !== undefined && (end < zone.end || (end === zone.end && own >= zone.name))) {
          continue;
        }
        zone = { end, name: own };
      }
      runs.push({ indices: run, timeZone: zone?.name });
      run = [];
    };
    let lastEnd: number | undefined;
    for (const index of indices.sort((a, b) => records[a]!.start - records[b]!.start)) {
      const record = records[index]!;
      if (lastEnd !== undefined && record.start - lastEnd >= sessionGap) close();
      run.push(index);
      lastEnd = Math.max(lastEnd ?? record.end, record.end);
    }
    close();
  }
  return runs;
};

/** Each of `records`' runs' zones (`sleepRuns`), in their order. */
export const sleepRunZones = (
  records: ReadonlyArray<CardSleepRecord>,
): Array<string | undefined> => {
  const zones = Array<string | undefined>(records.length).fill(undefined);
  for (const run of sleepRuns(records)) {
    for (const index of run.indices) zones[index] = run.timeZone;
  }
  return zones;
};

/**
 * Days of sleep records' starts on their nights' clocks (`cardNights`), as the calendar's days: per
 * day, not per record, as the cards' time-zone math is (851-2906).
 */
class NightDays {
  private readonly calendar: CardCalendar;
  /**
   * The calendar's bucketer, then one for each other zone, with its days' starts mapped to the
   * calendar's days.
   */
  private readonly clocks: Array<{ bucketer: CardBucketer; days: Map<number, number> }>;
  private readonly indices = new Map<string, number>();

  constructor(calendar: CardCalendar) {
    this.calendar = calendar;
    this.clocks = [{ bucketer: new CardBucketer(calendar, "day"), days: new Map() }];
  }

  /** Which clock places records in `timeZone`: 0, the calendar's, for none or the calendar's. */
  clock(timeZone: string | undefined): number {
    if (timeZone === undefined) return 0;
    const known = this.indices.get(timeZone);
    if (known !== undefined) return known;
    const zoned = zonedCalendar(this.calendar, timeZone);
    if (zoned === undefined) return 0;
    this.clocks.push({ bucketer: new CardBucketer(zoned, "day"), days: new Map() });
    this.indices.set(timeZone, this.clocks.length - 1);
    return this.clocks.length - 1;
  }

  day(millis: number, clock: number): number {
    const { bucketer, days } = this.clocks[clock]!;
    const start = bucketer.startOf(millis);
    if (clock === 0) return start;
    const known = days.get(start);
    if (known !== undefined) return known;
    const day = sameDate(start, bucketer.calendar, this.calendar);
    days.set(start, day);
    return day;
  }
}

/**
 * `records` (none In Bed) with their runs' zones (`sleepRuns`) and their days on those zones'
 * clocks, as the calendar's days, in `records`' order. Zones are looked up once a run, not once a
 * record.
 */
const placeRecords = (
  records: ReadonlyArray<CardSleepRecord>,
  calendar: CardCalendar,
): Array<{ readonly placed: Placed; readonly day: number }> => {
  const days = new NightDays(calendar);
  const placed = Array<{ readonly placed: Placed; readonly day: number }>(records.length);
  for (const run of sleepRuns(records)) {
    const clock = days.clock(run.timeZone);
    for (const index of run.indices) {
      const record = records[index]!;
      placed[index] = {
        placed: { record, timeZone: run.timeZone },
        day: days.day(record.start + nightStartOffset, clock),
      };
    }
  }
  return placed;
};

const asleepTime = (records: ReadonlyArray<Placed>) =>
  records.reduce((total, { record }) => total + (isAsleep(record) ? duration(record) : 0), 0);

/**
 * The session with the most sleep among `records`, splitting where sleep stops for `sessionGap` or
 * more. Of sessions with as much sleep, the first.
 */
const mainSession = (records: ReadonlyArray<Placed>): ReadonlyArray<Placed> => {
  const sessions: Array<Array<Placed>> = [];
  let lastEnd: number | undefined;
  for (const placed of [...records].sort((a, b) => a.record.start - b.record.start)) {
    const { record } = placed;
    const session = sessions.at(-1);
    if (lastEnd !== undefined && record.start - lastEnd < sessionGap && session !== undefined) {
      session.push(placed);
    } else {
      sessions.push([placed]);
    }
    lastEnd = Math.max(lastEnd ?? record.end, record.end);
  }
  let best: ReadonlyArray<Placed> = sessions[0] ?? [];
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
 * - **The zone** (851-4175): each source's records (but In Bed) are split into runs where sleep
 *   stops for `sessionGap` or more, in absolute time, as sessions are. A run's zone is that of the
 *   last-ending of its records that have one (ties to the name that sorts first), else the
 *   calendar's (none). A night's main session is part of one run, so the night has its run's zone.
 *   Records in one zone, or in none, give the nights they always did.
 * - **The day:** a record belongs to the day `nightStartOffset` after its start on its run's zone's
 *   clock: the calendar's day of that date. Only the nights of `days` are kept.
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
  const known = records.filter(isKnown);
  const inBedRecords = known.filter((record) => record.value === sleepStages.inBed);
  const byDay = new Map<number, Array<Placed>>();
  const placed = placeRecords(
    known.filter((record) => record.value !== sleepStages.inBed),
    calendar,
  );
  for (const { placed: record, day } of placed) {
    if (day < days.start || day >= days.end) continue;
    const night = byDay.get(day);
    if (night === undefined) byDay.set(day, [record]);
    else night.push(record);
  }
  const nights: Array<CardNight> = [];
  for (const [day, dayRecords] of byDay) {
    // Milliseconds, so a tie between two sources' time asleep is exact on every engine.
    const asleepBySource = new Map<string, number>();
    for (const { record } of dayRecords) {
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
    const session = mainSession(dayRecords.filter(({ record }) => record.source === source));
    if (session.length === 0) continue;
    let start = Infinity;
    let end = -Infinity;
    for (const { record } of session) {
      start = Math.min(start, record.start);
      end = Math.max(end, record.end);
    }
    const inBed = union(inBedRecords.filter((record) => record.start < end && record.end > start));
    const timeZone = session[0]!.timeZone;
    nights.push({
      day,
      ...(timeZone !== undefined && { timeZone }),
      records: session.map(({ record }) => record).sort((a, b) => a.start - b.start),
      start,
      end,
      inBed: inBed > 0 ? inBed : end - start,
    });
  }
  return nights.sort((a, b) => a.day - b.day);
};
