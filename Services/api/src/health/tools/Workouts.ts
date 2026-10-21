import { Clock, Effect, Option, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { workoutActivityName } from "../HealthCatalog.ts";
import { workoutsStarting, workoutTotals } from "./HealthQueries.ts";
import { type HealthToolkit, workoutsLimit } from "./HealthToolkit.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";

type WorkoutsResult = (typeof HealthToolkit.tools.workouts.successSchema)["Type"];

/**
 * A workout's statistics by quantity type, in the catalog's units. Read as the Mac reads them
 * (`HealthWorkout.decodedStatistics`): all of them or, if one can't be read, none.
 */
const WorkoutStatistics = Schema.fromJsonString(
  Schema.Record(
    Schema.String,
    Schema.Struct({
      unit: Schema.String,
      sum: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
      average: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
      minimum: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
      maximum: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
    }),
  ),
);
const decodeStatistics = Schema.decodeUnknownOption(WorkoutStatistics);
type WorkoutStatistics = (typeof WorkoutStatistics)["Type"];

/** The kinds of distance a workout can record, the usual ones first. */
const distanceTypes = [
  "HKQuantityTypeIdentifierDistanceWalkingRunning",
  "HKQuantityTypeIdentifierDistanceCycling",
  "HKQuantityTypeIdentifierDistanceSwimming",
  "HKQuantityTypeIdentifierDistanceWheelchair",
  "HKQuantityTypeIdentifierDistanceDownhillSnowSports",
  "HKQuantityTypeIdentifierDistanceCrossCountrySkiing",
  "HKQuantityTypeIdentifierDistancePaddleSports",
  "HKQuantityTypeIdentifierDistanceRowing",
  "HKQuantityTypeIdentifierDistanceSkatingSports",
];

/**
 * The `workouts` tool from the user's store: the workouts that start in the period, newest first,
 * at most `workoutsLimit`, with the period's count and total time.
 */
export const healthWorkouts = Effect.fn("healthWorkouts")(function* (
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
  const totals = workoutTotals(sql, period.start, period.end);
  const result: WorkoutsResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count: totals.count,
    duration: totals.duration,
    workouts: workoutsStarting(sql, period.start, period.end, workoutsLimit).map((workout) => {
      const statistics: WorkoutStatistics = Option.getOrElse(
        decodeStatistics(workout.statistics),
        () => ({}),
      );
      const sum = (type: string) => statistics[type]?.sum ?? null;
      return {
        id: workout.id,
        activityType: workout.activityType,
        activity: workoutActivityName(workout.activityType),
        start: localTime(workout.startDate, zone),
        end: localTime(workout.endDate, zone),
        duration: workout.duration,
        activeEnergy: sum("HKQuantityTypeIdentifierActiveEnergyBurned"),
        distance: distanceTypes.map(sum).find((distance) => distance !== null) ?? null,
        averageHeartRate: statistics["HKQuantityTypeIdentifierHeartRate"]?.average ?? null,
        source: workout.sourceName,
      };
    }),
  };
  return result;
});
