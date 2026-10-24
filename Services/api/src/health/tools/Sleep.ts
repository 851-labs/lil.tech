import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { type CardCalendar, defaultCardWeekday } from "../cards/CardCalendar.ts";
import {
  type CardSleepRecord,
  cardNights,
  isAsleep,
  nightRecordRange,
  type SleepStage,
  sleepStages,
} from "../cards/CardNights.ts";
import { cardSleepRecords } from "../cards/CardQueries.ts";
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

// Nights of sleep as the Mac's Sleep page has them (`HealthDatabase.sleepNights`, which groups
// them with the cards' core, 851-3196), so both MCP servers give the same nights.

const duration = (record: CardSleepRecord) => record.end - record.start;

/**
 * The nights from `firstDay` to `lastDay` (starts of days in the calendar's zone), oldest first,
 * leaving out nights without sleep, grouped as cards' sleep windows group them (`cardNights`): one
 * source a night, its main session, and in bed from every source's In Bed records.
 */
const sleepNights = (sql: StoreSql, firstDay: number, lastDay: number, calendar: CardCalendar) => {
  const days = { start: firstDay, end: startOfDay(lastDay, calendar.zone, 1) };
  return cardNights(cardSleepRecords(sql, nightRecordRange(days)), days, calendar);
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
  const stageTime = (records: ReadonlyArray<CardSleepRecord>, stage: SleepStage) =>
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
      awake: stageTime(night.records, sleepStages.awake),
      core: stageTime(night.records, sleepStages.core),
      deep: stageTime(night.records, sleepStages.deep),
      rem: stageTime(night.records, sleepStages.rem),
      unspecified: stageTime(night.records, sleepStages.asleep),
    })),
  };
  return result;
});
