import { Clock, Effect, Option, Predicate, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { workoutActivityName } from "../HealthCatalog.ts";
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
      /** Its configuration's `HKWorkoutSessionLocationType`, from iPhones since 851-4030. */
      locationType: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
      /** Its configuration's `HKWorkoutSwimmingLocationType`, from iPhones since 851-4030. */
      swimmingLocationType: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
      metadata: Schema.optionalKey(Schema.NullOr(Metadata)),
    }),
  ),
);
type WorkoutActivity = (typeof WorkoutActivities)["Type"][number];
const decodeActivities = Schema.decodeUnknownOption(WorkoutActivities);

/** `HKMetadataKeyIndoorWorkout`: a Boolean, or 0 or 1 from apps that write it as a number. */
const indoor = (metadata: Metadata | null | undefined): boolean | null => {
  const value = metadata?.["HKIndoorWorkout"];
  if (Predicate.isBoolean(value)) return value;
  return value === 1 ? true : value === 0 ? false : null;
};

/** An `HKWorkoutSwimmingLocationType`'s name: 1 pool, 2 open water, else (0, unknown) null. */
const swimmingLocationName = (value: unknown): string | null =>
  value === 1 ? "pool" : value === 2 ? "openWater" : null;

/** `HKMetadataKeySwimmingLocationType`, an `HKWorkoutSwimmingLocationType`. */
const swimmingLocation = (metadata: Metadata | null | undefined): string | null =>
  swimmingLocationName(metadata?.["HKSwimmingLocationType"]);

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

/**
 * Whether an activity was indoors: as its metadata says, else as its configuration's
 * `HKWorkoutSessionLocationType` does (2 indoor, 3 outdoor, 1 unknown).
 */
const activityIndoor = (activity: WorkoutActivity): boolean | null => {
  const type = activity.locationType;
  return indoor(activity.metadata) ?? (type === 2 ? true : type === 3 ? false : null);
};

/**
 * An activity's pool or open water: as its metadata says, else as its configuration's
 * `HKWorkoutSwimmingLocationType` does (1 pool, 2 open water, 0 unknown).
 */
const activitySwimmingLocation = (activity: WorkoutActivity): string | null =>
  swimmingLocation(activity.metadata) ?? swimmingLocationName(activity.swimmingLocationType);

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

/**
 * Whether a workout was indoors: as its metadata says or, if it doesn't, as its activities say
 * they were, if they agree. A workout of one activity may only say so on its activity, or its
 * configuration.
 */
const workoutIndoor = (
  metadata: Metadata | null,
  activities: ReadonlyArray<WorkoutActivity>,
): boolean | null => indoor(metadata) ?? agreed(activities, activityIndoor);

/**
 * Whether a workout was indoors, from its `metadata` and `activities` columns, as the tool's
 * `indoor` says: what cards' workout windows keep by (851-4031).
 */
export const storedWorkoutIndoor = (metadata: unknown, activities: unknown): boolean | null =>
  workoutIndoor(
    Option.getOrNull(decodeMetadata(metadata)),
    Option.getOrElse(decodeActivities(activities), () => []),
  );

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
