import { Clock, Effect, Option, Predicate, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { workoutActivityName } from "../HealthCatalog.ts";
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
import { workoutsStarting, workoutsWithRoutes, workoutTotals } from "./HealthQueries.ts";
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

/** A string unless it's blank: only spaces, tabs and line breaks, which the Mac counts the same. */
const unlessBlank = (value: unknown): string | null =>
  Predicate.isString(value) && !/^[ \t\n\r]*$/.test(value) ? value : null;

/**
 * The workout's name: `HKMetadataKeyWorkoutBrandName`, else the name of the WorkoutKit plan it was
 * recorded from, which the iPhone keeps in its metadata (`LilWorkoutPlan`, 851-4030), unless
 * they're blank (`WorkoutMetadata` on the Mac).
 */
const workoutName = (metadata: Metadata | null): string | null => {
  const plan = metadata?.["LilWorkoutPlan"];
  return (
    unlessBlank(metadata?.["HKWorkoutBrandName"]) ??
    (Predicate.isObject(plan) ? unlessBlank(plan["name"]) : null)
  );
};

/** Meters in each length unit HealthKit writes a quantity in (`HKUnit`'s unit strings). */
const meters: Record<string, number> = {
  mm: 0.001,
  cm: 0.01,
  m: 1,
  km: 1000,
  in: 0.0254,
  ft: 0.3048,
  yd: 0.9144,
  mi: 1609.344,
};

/**
 * `HKMetadataKeyElevationAscended` in meters. The iPhone writes quantities as their description,
 * a number and a unit ("4250 cm"); anything else, or another unit, is null.
 */
const elevationAscended = (metadata: Metadata | null): number | null => {
  const value = metadata?.["HKElevationAscended"];
  if (!Predicate.isString(value)) return null;
  const match = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?) (\S+)$/.exec(value);
  const factor = match === null ? undefined : meters[match[2]!];
  if (match === null || factor === undefined) return null;
  const elevation = Number(match[1]) * factor;
  return Number.isFinite(elevation) ? elevation : null;
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
    workouts: workouts.map((workout) => {
      const statistics: WorkoutStatistics = Option.getOrElse(
        decodeStatistics(workout.statistics),
        () => ({}),
      );
      const sum = (type: string) => statistics[type]?.sum ?? null;
      const metadata = Option.getOrNull(decodeMetadata(workout.metadata));
      const activities = Option.getOrElse(decodeActivities(workout.activities), () => []);
      return {
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
        elevationAscended: elevationAscended(metadata),
        indoor: workoutIndoor(metadata, activities),
        swimmingLocation:
          swimmingLocation(metadata) ?? agreed(activities, activitySwimmingLocation),
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
    }),
  };
  return result;
});
