import { Option, Predicate, Schema } from "effect";

// A workout's `metadata` and `activities` columns as the Health tools and the cards' workout
// windows read them (851-4015, 851-4030, 851-4031): where it was, indoors or not and in a pool or
// open water. The Mac reads them alike (`WorkoutMetadata` in `HealthDatabase`, with the rule in
// `HealthCards`' `CardWorkout`). It's its own module so the cards' engine doesn't depend on the
// tools'.

/** Metadata as HealthKit keys it (`HealthEncoder.json` on the iPhone), or none if not an object. */
export const Metadata = Schema.Record(Schema.String, Schema.Unknown);
export type Metadata = (typeof Metadata)["Type"];
export const decodeMetadata = Schema.decodeUnknownOption(Schema.fromJsonString(Metadata));

/**
 * A workout's activities (the legs of a multisport workout), with what the tool reads of them.
 * Read like its statistics: all of them or, if one can't be read, none.
 */
export const WorkoutActivities = Schema.fromJsonString(
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
export type WorkoutActivity = (typeof WorkoutActivities)["Type"][number];
export const decodeActivities = Schema.decodeUnknownOption(WorkoutActivities);

/** `HKMetadataKeyIndoorWorkout`: a Boolean, or 0 or 1 from apps that write it as a number. */
export const indoor = (metadata: Metadata | null | undefined): boolean | null => {
  const value = metadata?.["HKIndoorWorkout"];
  if (Predicate.isBoolean(value)) return value;
  return value === 1 ? true : value === 0 ? false : null;
};

/** An `HKWorkoutSwimmingLocationType`'s name: 1 pool, 2 open water, else (0, unknown) null. */
export const swimmingLocationName = (value: unknown): string | null =>
  value === 1 ? "pool" : value === 2 ? "openWater" : null;

/** `HKMetadataKeySwimmingLocationType`, an `HKWorkoutSwimmingLocationType`. */
export const swimmingLocation = (metadata: Metadata | null | undefined): string | null =>
  swimmingLocationName(metadata?.["HKSwimmingLocationType"]);

/**
 * Whether an activity was indoors: as its metadata says, else as its configuration's
 * `HKWorkoutSessionLocationType` does (2 indoor, 3 outdoor, 1 unknown).
 */
export const activityIndoor = (activity: WorkoutActivity): boolean | null => {
  const type = activity.locationType;
  return indoor(activity.metadata) ?? (type === 2 ? true : type === 3 ? false : null);
};

/**
 * An activity's pool or open water: as its metadata says, else as its configuration's
 * `HKWorkoutSwimmingLocationType` does (1 pool, 2 open water, 0 unknown).
 */
export const activitySwimmingLocation = (activity: WorkoutActivity): string | null =>
  swimmingLocation(activity.metadata) ?? swimmingLocationName(activity.swimmingLocationType);

/**
 * What `read` gives for those of `values` it gives anything for, if they agree; else null. A
 * multisport workout's transitions don't say where they were.
 */
export const agreed = <A, B>(values: ReadonlyArray<A>, read: (value: A) => B | null): B | null => {
  const given = values.map(read).filter((value) => value !== null);
  return given.length > 0 && given.every((value) => value === given[0]) ? given[0]! : null;
};

/**
 * Whether a workout was indoors: as its metadata says or, if it doesn't, as its activities say
 * they were, if they agree. A workout of one activity may only say so on its activity, or its
 * configuration.
 */
export const workoutIndoor = (
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
