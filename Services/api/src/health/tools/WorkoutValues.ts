import { metadataValue } from "../MetadataValues.ts";
import type { Metadata } from "../WorkoutMetadata.ts";

// What the Health tools read of a workout's metadata beyond where it was (851-4165): HealthKit's
// keys for elevation, speeds, METs, the weather, pool length, SWOLF and strokes, on the workout,
// its activities and its events, each read as `MetadataValues.ts` reads it (851-4170): null when
// it doesn't say, in a unit it isn't read in. The Mac reads them alike (`WorkoutMetadata` in
// `HealthDatabase`), so the two `workout` tools agree (the conformance cases).

/** Speeds, in meters per second. */
const speedFields = (metadata: Metadata | null | undefined) => ({
  averageSpeed: metadataValue(metadata, "HKAverageSpeed"),
  maximumSpeed: metadataValue(metadata, "HKMaximumSpeed"),
});

/** What a workout's or an activity's metadata says beyond where it was. */
export const workoutMetadataValues = (metadata: Metadata | null | undefined) => ({
  elevationAscended: metadataValue(metadata, "HKElevationAscended"),
  elevationDescended: metadataValue(metadata, "HKElevationDescended"),
  ...speedFields(metadata),
  averageMETs: metadataValue(metadata, "HKAverageMETs"),
  lapLength: metadataValue(metadata, "HKLapLength"),
  swolf: metadataValue(metadata, "HKSWOLFScore"),
});

/** The weather a workout's metadata gives. */
export const workoutWeather = (metadata: Metadata | null | undefined) => ({
  weatherCondition: metadataValue(metadata, "HKWeatherCondition"),
  weatherTemperature: metadataValue(metadata, "HKWeatherTemperature"),
  weatherHumidity: metadataValue(metadata, "HKWeatherHumidity"),
});

/** What a lap's or segment's metadata says. */
export const intervalValues = (metadata: Metadata | null | undefined) => ({
  strokeStyle: metadataValue(metadata, "HKSwimmingStrokeStyle"),
  swolf: metadataValue(metadata, "HKSWOLFScore"),
  lapLength: metadataValue(metadata, "HKLapLength"),
  ...speedFields(metadata),
});
