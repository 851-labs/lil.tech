import { Clock, type DateTime, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { samplesOverlapping } from "./HealthQueries.ts";
import type { HealthToolkit } from "./HealthToolkit.ts";
import {
  localDate,
  localTime,
  startOfDay,
  type ToolRange,
  toolPeriod,
  toolTimeZone,
} from "./ToolTime.ts";

type SleepResult = (typeof HealthToolkit.tools.sleep.successSchema)["Type"];

// Nights of sleep as the Mac's Sleep page has them (`HealthDatabase.sleepNights`), so both MCP
// servers give the same nights.

const sleepType = "HKCategoryTypeIdentifierSleepAnalysis";

/** `HKCategoryValueSleepAnalysis`'s raw values. */
const stages = { inBed: 0, asleep: 1, awake: 2, core: 3, deep: 4, rem: 5 } as const;
type Stage = (typeof stages)[keyof typeof stages];
const isStage = (value: number | null): value is Stage =>
  value !== null && Number.isInteger(value) && value >= 0 && value <= 5;
/** Time asleep: every stage but in bed and awake. */
const isAsleep = (stage: Stage) => stage !== stages.inBed && stage !== stages.awake;

const hourMillis = 60 * 60 * 1000;

/**
 * How far before midnight a night can start: sleep from 6 PM counts toward the next day, as in
 * Health, so a night that starts at 23:00 is the next day's and an afternoon nap its own day's.
 */
const nightStartOffset = 6 * hourMillis;

/** A gap this long between stretches of sleep starts a new session: a nap after the night. */
const sessionGap = 3 * hourMillis;

interface Segment {
  readonly stage: Stage;
  readonly start: number;
  readonly end: number;
}

const duration = (segment: Segment) => segment.end - segment.start;

const asleep = (segments: ReadonlyArray<Segment>) =>
  segments.reduce((total, segment) => total + (isAsleep(segment.stage) ? duration(segment) : 0), 0);

/**
 * The session with the most sleep among `segments` (by start), splitting where sleep stops for
 * `sessionGap` or more. Of sessions with as much sleep, the first.
 */
const mainSession = (segments: ReadonlyArray<Segment>): ReadonlyArray<Segment> => {
  const sessions: Array<Array<Segment>> = [];
  let lastEnd: number | undefined;
  for (const segment of [...segments].sort((a, b) => a.start - b.start)) {
    const session = sessions.at(-1);
    if (lastEnd !== undefined && segment.start - lastEnd < sessionGap && session !== undefined) {
      session.push(segment);
    } else {
      sessions.push([segment]);
    }
    lastEnd = Math.max(lastEnd ?? segment.end, segment.end);
  }
  return sessions.reduce<ReadonlyArray<Segment>>(
    (best, session) => (asleep(session) > asleep(best) ? session : best),
    sessions[0] ?? [],
  );
};

/** The total time `segments` cover, counting overlaps once. */
const union = (segments: ReadonlyArray<Segment>) => {
  let total = 0;
  let open: { start: number; end: number } | undefined;
  for (const segment of [...segments].sort((a, b) => a.start - b.start)) {
    if (open !== undefined && segment.start <= open.end) {
      open.end = Math.max(open.end, segment.end);
    } else {
      if (open !== undefined) total += open.end - open.start;
      open = { start: segment.start, end: segment.end };
    }
  }
  return open === undefined ? total : total + open.end - open.start;
};

/**
 * The nights from `firstDay` to `lastDay` (starts of days in `zone`), oldest first, leaving out
 * nights without sleep.
 * - **Source:** each night uses one source, the one that recorded the most time asleep that day
 *   (ties go to the lower bundle ID), so overlapping sources don't add up.
 * - **The night:** that source's longest session, its stretches of sleep with gaps under 3
 *   hours. Naps on the same day aren't part of it.
 * - **In bed:** every source's in-bed records that overlap the night, counted once, wherever they
 *   start. Without any, the night's span.
 */
const sleepNights = (sql: StoreSql, firstDay: number, lastDay: number, zone: DateTime.TimeZone) => {
  const lower = firstDay - nightStartOffset;
  const upper = startOfDay(lastDay, zone, 1) - nightStartOffset;
  const records = samplesOverlapping(sql, sleepType, lower, upper).flatMap((sample) =>
    isStage(sample.categoryValue)
      ? [
          {
            segment: { stage: sample.categoryValue, start: sample.startDate, end: sample.endDate },
            source: sample.sourceBundleId,
          },
        ]
      : [],
  );
  const inBedRecords = records
    .filter(({ segment }) => segment.stage === stages.inBed)
    .map(({ segment }) => segment);
  const byNight = new Map<number, Array<(typeof records)[number]>>();
  for (const record of records) {
    if (record.segment.stage === stages.inBed || record.segment.start < lower) continue;
    const day = startOfDay(record.segment.start + nightStartOffset, zone);
    byNight.set(day, [...(byNight.get(day) ?? []), record]);
  }
  return [...byNight.entries()]
    .flatMap(([day, records]) => {
      const asleepBySource = new Map<string, number>();
      for (const { segment, source } of records) {
        if (isAsleep(segment.stage)) {
          asleepBySource.set(source, (asleepBySource.get(source) ?? 0) + duration(segment));
        }
      }
      let source: string | undefined;
      for (const [candidate, time] of asleepBySource) {
        const best = source === undefined ? undefined : asleepBySource.get(source)!;
        if (best === undefined || time > best || (time === best && candidate < source!)) {
          source = candidate;
        }
      }
      if (source === undefined) return [];
      const segments = mainSession(
        records.filter((record) => record.source === source).map(({ segment }) => segment),
      );
      if (segments.length === 0) return [];
      const start = Math.min(...segments.map((segment) => segment.start));
      const end = Math.max(...segments.map((segment) => segment.end));
      const inBed = union(
        inBedRecords.filter((record) => record.start < end && record.end > start),
      );
      return [{ day, segments, start, end, inBed: inBed > 0 ? inBed : end - start }];
    })
    .sort((a, b) => a.day - b.day);
};

/** The `sleep` tool from the user's store: each night that ends in the period, oldest first. */
export const healthSleep = Effect.fn("healthSleep")(function* (
  sql: StoreSql,
  input: {
    readonly range: ToolRange;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const period = toolPeriod(input.range, input.date, now, zone);
  const nights = sleepNights(sql, period.start, startOfDay(period.end, zone, -1), zone);
  const seconds = (millis: number) => millis / 1000;
  const stageTime = (segments: ReadonlyArray<Segment>, stage: Stage) =>
    seconds(
      segments.reduce(
        (total, segment) => total + (segment.stage === stage ? duration(segment) : 0),
        0,
      ),
    );
  const result: SleepResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    nights: nights.map((night) => ({
      date: localDate(night.day, zone),
      start: localTime(night.start, zone),
      end: localTime(night.end, zone),
      inBed: seconds(night.inBed),
      asleep: seconds(asleep(night.segments)),
      awake: stageTime(night.segments, stages.awake),
      core: stageTime(night.segments, stages.core),
      deep: stageTime(night.segments, stages.deep),
      rem: stageTime(night.segments, stages.rem),
      unspecified: stageTime(night.segments, stages.asleep),
    })),
  };
  return result;
});
