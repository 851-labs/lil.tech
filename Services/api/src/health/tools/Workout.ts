import { type DateTime, Effect, Option, Predicate, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { healthCatalogType } from "../HealthCatalog.ts";
import { Metadata } from "../WorkoutMetadata.ts";
import { workoutsWithRoutes, workoutWithId } from "./HealthQueries.ts";
import { HealthToolError, type HealthToolkit, workoutEventsLimit } from "./HealthToolkit.ts";
import { workoutEffort, workoutLinksRead } from "./Links.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { localTime, toolTimeZone } from "./ToolTime.ts";
import { intervalValues, workoutMetadataValues, workoutWeather } from "./WorkoutValues.ts";
import { readWorkout, StatisticsByType, type WorkoutStatistics } from "./Workouts.ts";

type WorkoutResult = (typeof HealthToolkit.tools.workout.successSchema)["Type"];
type WorkoutDetail = WorkoutResult["workout"];

/**
 * A workout's events (`HKWorkoutEvent`), in the order HealthKit gave them: all of them or, if one
 * can't be read, none. A `metadata` that isn't an object is taken for none.
 */
const WorkoutEvents = Schema.fromJsonString(
  Schema.Array(
    Schema.Struct({
      /** `HKWorkoutEventType`'s raw value. */
      type: Schema.Int,
      startDate: Schema.Int,
      endDate: Schema.Int,
      metadata: Schema.optionalKey(Schema.Unknown),
    }),
  ),
);
type WorkoutEvent = (typeof WorkoutEvents)["Type"][number];
const decodeEvents = Schema.decodeUnknownOption(WorkoutEvents);
const asMetadata = Schema.decodeUnknownOption(Metadata);
const decodeStatistics = Schema.decodeUnknownOption(StatisticsByType);

/** `HKWorkoutEventType`'s raw values. */
const eventType = { pause: 1, resume: 2, lap: 3, motionPaused: 5, motionResumed: 6, segment: 7 };

/** Statistics by type as the output lists them: by type identifier. */
const statisticsList = (statistics: WorkoutStatistics) =>
  Object.keys(statistics)
    .sort()
    .map((type) => {
      const statistic = statistics[type]!;
      return {
        type,
        name: healthCatalogType(type)?.name ?? null,
        unit: statistic.unit,
        sum: statistic.sum ?? null,
        average: statistic.average ?? null,
        minimum: statistic.minimum ?? null,
        maximum: statistic.maximum ?? null,
        mostRecent: statistic.mostRecent ?? null,
      };
    });

/**
 * When it was paused, as the Mac's workout page finds its pauses (`HealthWorkout.pauses`): from
 * each pause (or motion pause) to the resume after it, or to the end. Events are taken by when
 * they start, ties in the order given.
 */
const pauses = (events: ReadonlyArray<WorkoutEvent>, end: number) => {
  const found: Array<readonly [number, number]> = [];
  let pausedAt: number | null = null;
  for (const event of events.toSorted((a, b) => a.startDate - b.startDate)) {
    if (event.type === eventType.pause || event.type === eventType.motionPaused) {
      pausedAt ??= event.startDate;
    } else if (event.type === eventType.resume || event.type === eventType.motionResumed) {
      if (pausedAt !== null && event.startDate > pausedAt) found.push([pausedAt, event.startDate]);
      pausedAt = null;
    }
  }
  if (pausedAt !== null && end > pausedAt) found.push([pausedAt, end]);
  return found;
};

/** The events of one type, by when they start (ties in the order given), as intervals. */
const intervals = (events: ReadonlyArray<WorkoutEvent>, type: number, zone: DateTime.TimeZone) =>
  events
    .filter((event) => event.type === type)
    .toSorted((a, b) => a.startDate - b.startDate)
    .map((event) => ({
      start: localTime(event.startDate, zone),
      end: localTime(event.endDate, zone),
      duration: (event.endDate - event.startDate) / 1000,
      ...intervalValues(Option.getOrNull(asMetadata(event.metadata))),
    }));

/**
 * The `workout` tool from the user's store: one workout, by its ID, with everything `workouts`
 * says of it and the rest of what the iPhone uploads (851-4165), its effort scores among them
 * (851-4187). Its statistics are HealthKit's, which it computes from the samples linked to it.
 */
export const healthWorkout = Effect.fn("healthWorkout")(function* (
  sql: StoreSql,
  input: { readonly id: string; readonly timeZone?: string | undefined },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const row = workoutWithId(sql, input.id);
  if (row === undefined) {
    return yield* new HealthToolError({
      message: `No workout with ID ${input.id}. workouts lists them, with their IDs.`,
    });
  }
  const { item, statistics, metadata, activities } = readWorkout(
    row,
    workoutsWithRoutes(sql, [row]),
    zone,
    new RecordedZones(),
  );
  const events = Option.getOrElse(decodeEvents(row.events), () => []);
  const paused = pauses(events, row.endDate);
  const laps = intervals(events, eventType.lap, zone);
  const segments = intervals(events, eventType.segment, zone);
  const effort = workoutEffort(sql, row.id);
  const workout: WorkoutDetail = {
    ...item,
    ...workoutMetadataValues(metadata),
    ...workoutWeather(metadata),
    linksRead: workoutLinksRead(sql, row.id),
    effort: effort.effort,
    statistics: statisticsList(statistics),
    pauseCount: paused.length,
    pauses: paused.slice(0, workoutEventsLimit).map(([start, end]) => ({
      start: localTime(start, zone),
      end: localTime(end, zone),
      duration: (end - start) / 1000,
    })),
    lapCount: laps.length,
    laps: laps.slice(0, workoutEventsLimit),
    segmentCount: segments.length,
    segments: segments.slice(0, workoutEventsLimit),
    activities: item.activities.map((leg, index) => {
      const activity = activities[index]!;
      return {
        ...leg,
        ...workoutMetadataValues(activity.metadata),
        effort:
          (Predicate.isString(activity.id) ? effort.legs.get(activity.id) : undefined) ?? null,
        statistics: statisticsList(
          Option.getOrElse(decodeStatistics(activity.statistics), () => ({})),
        ),
      };
    }),
  };
  const result: WorkoutResult = { timeZone: name, workout };
  return result;
});
