import type { StoreSql } from "../../store/StoreSql.ts";
import { healthDetails } from "./Details.ts";
import type { Effect } from "effect";
import type { HealthToolError, HealthToolkit } from "./HealthToolkit.ts";
import { healthListTypes } from "./ListTypes.ts";
import { healthMedications } from "./Medications.ts";
import { healthMetric } from "./Metric.ts";
import { healthSamples } from "./Samples.ts";
import { healthSearch } from "./Search.ts";
import { healthSleep } from "./Sleep.ts";
import { healthSummary } from "./Summary.ts";
import { healthSyncStatus } from "./SyncStatus.ts";
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
 * the Mac's answers.
 */
export const storeHealthTools = (sql: StoreSql): HealthToolImplementations => ({
  summary: (params) => healthSummary(sql, params),
  list_types: (params) => healthListTypes(sql, params),
  metric: (params) => healthMetric(sql, params),
  samples: (params) => healthSamples(sql, params),
  workouts: (params) => healthWorkouts(sql, params),
  sleep: (params) => healthSleep(sql, params),
  medications: (params) => healthMedications(sql, params),
  health_details: (params) => healthDetails(sql, params),
  search: (params) => healthSearch(sql, params),
  sync_status: (params) => healthSyncStatus(sql, params),
});
