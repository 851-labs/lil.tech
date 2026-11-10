import { Clock, type DateTime, Effect, Option, Predicate, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { workoutActivityName } from "../HealthCatalog.ts";
import { metadataValue, text } from "../MetadataValues.ts";
import {
  activityIndoor,
  activitySwimmingLocation,
  agreed,
  decodeActivities,
  decodeMetadata,
  type Metadata,
  swimmingLocation,
  workoutIndoor,
} from "../WorkoutMetadata.ts";
import {
  type WorkoutRow,
  workoutsStarting,
  workoutsWithRoutes,
  workoutTotals,
} from "./HealthQueries.ts";
import { type HealthToolkit, workoutsLimit } from "./HealthToolkit.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";

type WorkoutsResult = (typeof HealthToolkit.tools.workouts.successSchema)["Type"];
type WorkoutItem = WorkoutsResult["workouts"][number];

/**
 * A workout's or an activity's statistics by quantity type, in the catalog's units. Read as the
 * Mac reads them (`HealthWorkout.decodedStatistics`): all of them or, if one can't be read, none.
 */
export const StatisticsByType = Schema.Record(
  Schema.String,
  Schema.Struct({
    unit: Schema.String,
    sum: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
    average: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
    minimum: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
    maximum: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
    mostRecent: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
  }),
);
export type WorkoutStatistics = (typeof StatisticsByType)["Type"];
const decodeStatistics = Schema.decodeUnknownOption(Schema.fromJsonString(StatisticsByType));

/**
 * The workout's name: `HKMetadataKeyWorkoutBrandName`, else the name of the WorkoutKit plan it was
 * recorded from, which the iPhone keeps in its metadata (`LilWorkoutPlan`, 851-4030), unless
 * they're blank (`WorkoutMetadata` on the Mac).
 */
const workoutName = (metadata: Metadata | null): string | null => {
  const plan = metadata?.["LilWorkoutPlan"];
  return (
    metadataValue(metadata, "HKWorkoutBrandName") ??
    (Predicate.isObject(plan) ? text(plan["name"]) : null)
  );
};

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
 * What `workouts` says of a workout, with the statistics, metadata and activities it read, which
 * `workout` adds to.
 */
export const readWorkout = (
  workout: WorkoutRow,
  withRoutes: ReadonlySet<string>,
  zone: DateTime.TimeZone,
) => {
  const statistics: WorkoutStatistics = Option.getOrElse(
    decodeStatistics(workout.statistics),
    () => ({}),
  );
  const sum = (type: string) => statistics[type]?.sum ?? null;
  const metadata = Option.getOrNull(decodeMetadata(workout.metadata));
  const activities = Option.getOrElse(decodeActivities(workout.activities), () => []);
  const item: WorkoutItem = {
    id: workout.id,
    activityType: workout.activityType,
    activity: workoutActivityName(workout.activityType),
    name: workoutName(metadata),
    start: localTime(workout.startDate, zone),
    end: localTime(workout.endDate, zone),
    duration: workout.duration,
    activeEnergy: sum("HKQuantityTypeIdentifierActiveEnergyBurned"),
    distance: distanceTypes.map(sum).find((distance) => distance !== null) ?? null,
    averageHeartRate: statistics["HKQuantityTypeIdentifierHeartRate"]?.average ?? null,
    elevationAscended: metadataValue(metadata, "HKElevationAscended"),
    indoor: workoutIndoor(metadata, activities),
    swimmingLocation: swimmingLocation(metadata) ?? agreed(activities, activitySwimmingLocation),
    hasRoute: withRoutes.has(workout.id),
    source: workout.sourceName,
    activities:
      activities.length < 2
        ? []
        : activities.map((activity) => ({
            activityType: activity.activityType,
            activity: workoutActivityName(activity.activityType),
            start: localTime(activity.startDate, zone),
            end: activity.endDate === null ? null : localTime(activity.endDate, zone),
            duration: activity.duration,
            indoor: activityIndoor(activity),
            swimmingLocation: activitySwimmingLocation(activity),
          })),
  };
  return { item, statistics, metadata, activities };
};

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
  const period = yield* toolPeriod(input.range, input.date, now, zone);
  const totals = workoutTotals(sql, period.start, period.end);
  const workouts = workoutsStarting(sql, period.start, period.end, workoutsLimit);
  const withRoutes = workoutsWithRoutes(sql, workouts);
  const result: WorkoutsResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count: totals.count,
    duration: totals.duration,
    workouts: workouts.map((workout) => readWorkout(workout, withRoutes, zone).item),
  };
  return result;
});
