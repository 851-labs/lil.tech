import { Clock, Effect, Option, Predicate, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { workoutActivityName } from "../HealthCatalog.ts";
import { workoutsStarting, workoutsWithRoutes, workoutTotals } from "./HealthQueries.ts";
import { type HealthToolkit, workoutsLimit } from "./HealthToolkit.ts";
import { localTime, type ToolRange, toolDate, toolPeriod, toolTimeZone } from "./ToolTime.ts";

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

/** Metadata as HealthKit keys it (`HealthEncoder.json` on the iPhone), or none if not an object. */
const Metadata = Schema.Record(Schema.String, Schema.Unknown);
type Metadata = (typeof Metadata)["Type"];
const decodeMetadata = Schema.decodeUnknownOption(Schema.fromJsonString(Metadata));

/**
 * A workout's activities (the legs of a multisport workout), with what the tool reads of them.
 * Read like its statistics: all of them or, if one can't be read, none.
 */
const WorkoutActivities = Schema.fromJsonString(
  Schema.Array(
    Schema.Struct({
      activityType: Schema.Int,
      startDate: Schema.Finite,
      endDate: Schema.NullOr(Schema.Finite),
      duration: Schema.Finite,
      metadata: Schema.optionalKey(Schema.NullOr(Metadata)),
    }),
  ),
);
const decodeActivities = Schema.decodeUnknownOption(WorkoutActivities);

/** `HKMetadataKeyIndoorWorkout`: a Boolean, or 0 or 1 from apps that write it as a number. */
const indoor = (metadata: Metadata | null | undefined): boolean | null => {
  const value = metadata?.["HKIndoorWorkout"];
  if (Predicate.isBoolean(value)) return value;
  return value === 1 ? true : value === 0 ? false : null;
};

/** `HKMetadataKeySwimmingLocationType`, an `HKWorkoutSwimmingLocationType`: 1 pool, 2 open water. */
const swimmingLocation = (metadata: Metadata | null | undefined): string | null => {
  const value = metadata?.["HKSwimmingLocationType"];
  return value === 1 ? "pool" : value === 2 ? "openWater" : null;
};

/**
 * `HKMetadataKeyWorkoutBrandName`, unless it's blank: only spaces, tabs and line breaks, which
 * the Mac counts the same (`WorkoutMetadata`).
 */
const brandName = (metadata: Metadata | null): string | null => {
  const value = metadata?.["HKWorkoutBrandName"];
  return Predicate.isString(value) && !/^[ \t\n\r]*$/.test(value) ? value : null;
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

/**
 * What `read` gives for those of `values` it gives anything for, if they agree; else null. A
 * multisport workout's transitions don't say where they were.
 */
const agreed = <A, B>(values: ReadonlyArray<A>, read: (value: A) => B | null): B | null => {
  const given = values.map(read).filter((value) => value !== null);
  return given.length > 0 && given.every((value) => value === given[0]) ? given[0]! : null;
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
  const period = toolPeriod(input.range, yield* toolDate(input.date), now, zone);
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
      // A workout that doesn't say is where its activities say they were, if they agree: a
      // workout of one activity may only say so on its activity.
      const activityMetadata = activities.map((activity) => activity.metadata);
      return {
        id: workout.id,
        activityType: workout.activityType,
        activity: workoutActivityName(workout.activityType),
        name: brandName(metadata),
        start: localTime(workout.startDate, zone),
        end: localTime(workout.endDate, zone),
        duration: workout.duration,
        activeEnergy: sum("HKQuantityTypeIdentifierActiveEnergyBurned"),
        distance: distanceTypes.map(sum).find((distance) => distance !== null) ?? null,
        averageHeartRate: statistics["HKQuantityTypeIdentifierHeartRate"]?.average ?? null,
        elevationAscended: elevationAscended(metadata),
        indoor: indoor(metadata) ?? agreed(activityMetadata, indoor),
        swimmingLocation: swimmingLocation(metadata) ?? agreed(activityMetadata, swimmingLocation),
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
                indoor: indoor(activity.metadata),
                swimmingLocation: swimmingLocation(activity.metadata),
              })),
      };
    }),
  };
  return result;
});
