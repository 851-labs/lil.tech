import { Option, Schema } from "effect";
import { metadataValue, named, swimmingLocations } from "./MetadataValues.ts";

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
      /**
       * Its `HKWorkoutActivity`'s UUID, lowercase, as effort scores' legs name it (851-4187).
       * Read loosely, so one that isn't a string leaves only its leg without a score.
       */
      id: Schema.optionalKey(Schema.Unknown),
      activityType: Schema.Int,
      startDate: Schema.Finite,
      endDate: Schema.NullOr(Schema.Finite),
      duration: Schema.Finite,
      /** Its configuration's `HKWorkoutSessionLocationType`, from iPhones since 851-4030. */
      locationType: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
      /** Its configuration's `HKWorkoutSwimmingLocationType`, from iPhones since 851-4030. */
      swimmingLocationType: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
      metadata: Schema.optionalKey(Schema.NullOr(Metadata)),
      /**
       * Its statistics, as the workout's are, which the `workout` tool reads on their own: ones
       * it can't read leave the activity without statistics (851-4165).
       */
      statistics: Schema.optionalKey(Schema.Unknown),
    }),
  ),
);
export type WorkoutActivity = (typeof WorkoutActivities)["Type"][number];
export const decodeActivities = Schema.decodeUnknownOption(WorkoutActivities);

/** `HKMetadataKeyIndoorWorkout`: a Boolean, or 0 or 1 from apps that write it as a number. */
export const indoor = (metadata: Metadata | null | undefined): boolean | null =>
  metadataValue(metadata, "HKIndoorWorkout");

/** An `HKWorkoutSwimmingLocationType`'s name: 1 pool, 2 open water, else (0, unknown) null. */
const swimmingLocationName = (value: unknown): string | null => named(swimmingLocations, value);

/** `HKMetadataKeySwimmingLocationType`, an `HKWorkoutSwimmingLocationType`. */
export const swimmingLocation = (metadata: Metadata | null | undefined): string | null =>
  metadataValue(metadata, "HKSwimmingLocationType");

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
