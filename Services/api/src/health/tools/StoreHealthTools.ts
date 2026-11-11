import type { StoreSql } from "../../store/StoreSql.ts";
import { healthActivityRings } from "./ActivityRings.ts";
import { healthAudiograms } from "./Audiograms.ts";
import { healthDetails } from "./Details.ts";
import { healthElectrocardiograms, healthElectrocardiogramVoltages } from "./Electrocardiograms.ts";
import type { Effect } from "effect";
import type { HealthToolError, HealthToolkit } from "./HealthToolkit.ts";
import { healthHeartbeatSeries, healthHeartbeatSeriesBeats } from "./HeartbeatSeries.ts";
import { healthListTypes } from "./ListTypes.ts";
import { healthMedicationDoses, healthMedications } from "./Medications.ts";
import { healthAssessments, healthStateOfMind } from "./MentalWellbeing.ts";
import { healthMetric } from "./Metric.ts";
import { healthSamples } from "./Samples.ts";
import { healthSearch } from "./Search.ts";
import { healthSleep } from "./Sleep.ts";
import { healthSummary } from "./Summary.ts";
import { healthSyncStatus } from "./SyncStatus.ts";
import { healthWorkout } from "./Workout.ts";
import {
  type HealthBlobReader,
  healthWorkoutRoute,
  healthWorkoutRoutePoints,
  healthWorkoutRoutes,
  noHealthBlobs,
} from "./WorkoutRoutes.ts";
import { healthWorkouts } from "./Workouts.ts";

type Tools = typeof HealthToolkit.tools;

/** Each tool's implementation: its decoded parameters to its output, or its error. */
export type HealthToolImplementations = {
  readonly [Name in keyof Tools]: (
    params: Tools[Name]["parametersSchema"]["Type"],
  ) => Effect.Effect<Tools[Name]["successSchema"]["Type"], HealthToolError>;
};

/**
 * The Health toolkit's tools on a user's store (851-2851, 851-2868), each following the Mac's
 * `HealthTools`: the remote MCP server serves them, and the conformance cases check them against
 * the Mac's answers. The route tools read the routes' locations, and `electrocardiogram_voltages`
 * an ECG's voltages, from the user's blobs, with `blobs`.
 */
export const storeHealthTools = (
  sql: StoreSql,
  blobs: HealthBlobReader = noHealthBlobs,
): HealthToolImplementations => ({
  summary: (params) => healthSummary(sql, params),
  list_types: (params) => healthListTypes(sql, params),
  metric: (params) => healthMetric(sql, params),
  samples: (params) => healthSamples(sql, params),
  workouts: (params) => healthWorkouts(sql, params),
  workout: (params) => healthWorkout(sql, params),
  workout_routes: (params) => healthWorkoutRoutes(sql, params),
  workout_route: (params) => healthWorkoutRoute(sql, blobs, params),
  workout_route_points: (params) => healthWorkoutRoutePoints(sql, blobs, params),
  sleep: (params) => healthSleep(sql, params),
  activity_rings: (params) => healthActivityRings(sql, params),
  state_of_mind: (params) => healthStateOfMind(sql, params),
  assessments: (params) => healthAssessments(sql, params),
  electrocardiograms: (params) => healthElectrocardiograms(sql, params),
  electrocardiogram_voltages: (params) => healthElectrocardiogramVoltages(sql, blobs, params),
  heartbeat_series: (params) => healthHeartbeatSeries(sql, params),
  heartbeat_series_beats: (params) => healthHeartbeatSeriesBeats(sql, params),
  audiograms: (params) => healthAudiograms(sql, params),
  medications: (params) => healthMedications(sql, params),
  medication_doses: (params) => healthMedicationDoses(sql, params),
  health_details: (params) => healthDetails(sql, params),
  search: (params) => healthSearch(sql, params),
  sync_status: (params) => healthSyncStatus(sql, params),
});
