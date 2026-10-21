import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import {
  cumulativeTotal,
  latestSample,
  statisticsDevices,
  statisticsSource,
  summaryPins,
  workoutTotals,
} from "./HealthQueries.ts";
import { type HealthToolkit, summaryDefaultTypes } from "./HealthToolkit.ts";
import { localDate, localTime, startOfDay, toolTimeZone } from "./ToolTime.ts";

type SummaryResult = (typeof HealthToolkit.tools.summary.successSchema)["Type"];

/**
 * The `summary` tool from the user's store: for each pinned type (else `summaryDefaultTypes`), its
 * latest sample that has started, and from the statistics source its total today and over the
 * last 7 days (today and the 6 days before, in the call's time zone), plus the workouts that
 * started in those 7 days.
 */
export const healthSummary = Effect.fn("healthSummary")(function* (
  sql: StoreSql,
  input: { readonly timeZone?: string | undefined },
) {
  const zone = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const today = startOfDay(now, zone);
  const tomorrow = startOfDay(now, zone, 1);
  const weekStart = startOfDay(now, zone, -6);
  const pins = summaryPins(sql);
  const source = statisticsSource(statisticsDevices(sql), now);
  const metrics = (pins.length > 0 ? pins : summaryDefaultTypes).map((type) => {
    const latest = latestSample(sql, type, now);
    const day = source === null ? null : cumulativeTotal(sql, source, type, today, tomorrow);
    const week = source === null ? null : cumulativeTotal(sql, source, type, weekStart, tomorrow);
    return {
      type,
      unit: latest?.unit ?? week?.unit ?? null,
      latest:
        latest === null
          ? null
          : {
              start: localTime(latest.startDate, zone),
              end: localTime(latest.endDate, zone),
              value: latest.value,
              categoryValue: latest.categoryValue,
            },
      today: day?.sum ?? null,
      last7Days: week?.sum ?? null,
    };
  });
  const result: SummaryResult = {
    timeZone: zone.id,
    date: localDate(now, zone),
    pinned: pins.length > 0,
    metrics,
    workouts: workoutTotals(sql, weekStart, tomorrow),
  };
  return result;
});
