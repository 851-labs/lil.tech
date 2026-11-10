import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { type ActivitySummaryRow, activitySummaries } from "./HealthQueries.ts";
import type { HealthToolkit } from "./HealthToolkit.ts";
import { localDate, localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";

type ActivityRingsResult = (typeof HealthToolkit.tools.activity_rings.successSchema)["Type"];
type ActivityDay = ActivityRingsResult["days"][number];

/**
 * A day's rings as the Mac's Activity Rings page reads them (`ActivityDay`): Move in kilocalories,
 * or in minutes in Move time, a missing value or goal 0; Exercise and Stand only with a goal above
 * 0 (an Apple Watch's), a missing value 0.
 */
export const activityDay = (summary: ActivitySummaryRow): ActivityDay => {
  const minutes = summary.activityMoveMode === "appleMoveTime";
  const ring = (value: number | null, goal: number, unit: string) => ({
    value: value ?? 0,
    goal,
    unit,
  });
  const withGoal = (value: number | null, goal: number | null, unit: string) =>
    goal === null || !(goal > 0) ? null : ring(value, goal, unit);
  return {
    date: summary.id,
    move: minutes
      ? ring(summary.appleMoveTime, summary.appleMoveTimeGoal ?? 0, "min")
      : ring(summary.activeEnergyBurned, summary.activeEnergyBurnedGoal ?? 0, "kcal"),
    exercise: withGoal(summary.appleExerciseTime, summary.appleExerciseTimeGoal, "min"),
    stand: withGoal(summary.appleStandHours, summary.appleStandHoursGoal, "hr"),
    paused: summary.paused,
  };
};

/**
 * The `activity_rings` tool from the user's store (851-4158): each day of the period with rings,
 * oldest first. Summaries are keyed by the iPhone's day, so the period's days pick them by date,
 * as the Mac's `HealthTools.activityRings` does.
 */
export const healthActivityRings = Effect.fn("healthActivityRings")(function* (
  sql: StoreSql,
  input: {
    readonly range: ToolRange;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const period = yield* toolPeriod(input.range, input.date, now, zone);
  const summaries = activitySummaries(
    sql,
    localDate(period.start, zone),
    localDate(period.end, zone),
  );
  const result: ActivityRingsResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    days: summaries.map(activityDay),
  };
  return result;
});
