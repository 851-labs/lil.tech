import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { samplesOverlapping } from "./HealthQueries.ts";
import type { HealthToolkit } from "./HealthToolkit.ts";
import { type CardCalendar, defaultCardWeekday } from "../cards/CardCalendar.ts";
import {
  type CardSleepRecord,
  cardNights,
  isAsleep,
  nightRecordRange,
} from "../cards/CardNights.ts";
import {
  localDate,
  localTime,
  startOfDay,
  type ToolRange,
  toolPeriod,
  toolTimeZone,
} from "./ToolTime.ts";

type SleepResult = (typeof HealthToolkit.tools.sleep.successSchema)["Type"];

// Nights of sleep as the Mac's Sleep page has them (`HealthDatabase.sleepNights`, which groups
// them with the cards' core, 851-3196), so both MCP servers give the same nights.

const sleepType = "HKCategoryTypeIdentifierSleepAnalysis";

/** `HKCategoryValueSleepAnalysis`'s raw values. */
const stages = { inBed: 0, asleep: 1, awake: 2, core: 3, deep: 4, rem: 5 } as const;
type Stage = (typeof stages)[keyof typeof stages];

const duration = (record: CardSleepRecord) => record.end - record.start;

/**
 * The nights from `firstDay` to `lastDay` (starts of days in the calendar's zone), oldest first, leaving out
 * nights without sleep, grouped as cards' sleep windows group them (`cardNights`): one source a
 * night, its main session, and in bed from every source's In Bed records.
 */
const sleepNights = (sql: StoreSql, firstDay: number, lastDay: number, calendar: CardCalendar) => {
  const days = { start: firstDay, end: startOfDay(lastDay, calendar.zone, 1) };
  const range = nightRecordRange(days);
  const records = samplesOverlapping(sql, sleepType, range.start, range.end).flatMap((sample) =>
    sample.categoryValue === null
      ? []
      : [
          {
            start: sample.startDate,
            end: sample.endDate,
            value: sample.categoryValue,
            source: sample.sourceBundleId,
          },
        ],
  );
  return cardNights(records, days, calendar).map((night) => ({
    ...night,
    start: night.records.reduce((least, record) => Math.min(least, record.start), Infinity),
    end: night.records.reduce((most, record) => Math.max(most, record.end), -Infinity),
  }));
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
  // Nights are days, which don't depend on the first weekday.
  const calendar = { zone, timeZone: name, firstWeekday: defaultCardWeekday };
  const nights = sleepNights(sql, period.start, startOfDay(period.end, zone, -1), calendar);
  const seconds = (millis: number) => millis / 1000;
  const stageTime = (records: ReadonlyArray<CardSleepRecord>, stage: Stage) =>
    seconds(
      records.reduce((total, record) => total + (record.value === stage ? duration(record) : 0), 0),
    );
  const asleep = (records: ReadonlyArray<CardSleepRecord>) =>
    records.reduce((total, record) => total + (isAsleep(record) ? duration(record) : 0), 0);
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
      asleep: seconds(asleep(night.records)),
      awake: stageTime(night.records, stages.awake),
      core: stageTime(night.records, stages.core),
      deep: stageTime(night.records, stages.deep),
      rem: stageTime(night.records, stages.rem),
      unspecified: stageTime(night.records, stages.asleep),
    })),
  };
  return result;
});
