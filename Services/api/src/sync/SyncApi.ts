import { Schema } from "effect";
import { HttpApiEndpoint, HttpApiGroup, OpenApi } from "effect/http-api";
import { Authorization } from "../auth/AuthApi.ts";
import { UserStoreUnavailable } from "../store/UserStores.ts";

// The sync part of the API definition (`docs/SYNC.md`). Like `Api.ts`, it holds no server code.

export const Change = Schema.Struct({
  /** Position in the log, increasing by exactly 1 per change. */
  seq: Schema.Int,
  entity: Schema.String,
  id: Schema.String,
  op: Schema.Literals(["upsert", "delete"]),
  /** The whole record after an upsert, with `camelCase` fields. Absent for deletes. */
  row: Schema.optionalKey(Schema.Record(Schema.String, Schema.Json)),
  /** When the change was written, in Unix milliseconds. */
  at: Schema.Int,
}).annotate({ identifier: "lil/api/sync/Change", description: "One entry of the change log" });

export const ChangesPage = Schema.Struct({
  epoch: Schema.Int,
  changes: Schema.Array(Change),
  /** The cursor for the next request: the last change's `seq`, or `after` if there were none. */
  next: Schema.Int,
  /** The newest `seq` in the store. */
  head: Schema.Int,
  /** Whether `next < head`. */
  hasMore: Schema.Boolean,
}).annotate({ identifier: "lil/api/sync/ChangesPage", description: "A page of the change log" });

/** The changes after the cursor were compacted away. The client bootstraps from a snapshot. */
export class ChangesCompacted extends Schema.TaggedError<ChangesCompacted>()(
  "ChangesCompacted",
  { reason: Schema.Literal("compacted") },
  { httpApiStatus: 410 },
) {}

/**
 * Documents integer query parameters as integers. HttpApi describes query parameters by their
 * string encoding (a numeric pattern), which generated clients would take as strings.
 */
const integerQueryParameters = (
  bounds: Record<string, { readonly minimum?: number; readonly maximum?: number }>,
) =>
  OpenApi.annotations({
    transform: (operation) => ({
      ...operation,
      parameters: (operation["parameters"] as Array<Record<string, unknown>>).map((parameter) => {
        const bound = bounds[parameter["name"] as string];
        return parameter["in"] === "query" && bound !== undefined
          ? { ...parameter, schema: { type: "integer", ...bound } }
          : parameter;
      }),
    }),
  });

export const defaultChangesLimit = 1000;
export const maxChangesLimit = 5000;

export class SyncApi extends HttpApiGroup.make("sync")
  .add(
    HttpApiEndpoint.get("changes", "/v1/sync/changes", {
      query: {
        /** The client's cursor: the `seq` of the last change it applied. 0 for nothing. */
        after: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))),
        /** How many changes to return: 1000 by default, at most 5000. */
        limit: Schema.optionalKey(
          Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: maxChangesLimit })),
        ),
      },
      success: ChangesPage,
      error: [ChangesCompacted, UserStoreUnavailable],
    }).annotateMerge(
      integerQueryParameters({
        after: { minimum: 0 },
        limit: { minimum: 1, maximum: maxChangesLimit },
      }),
    ),
  )
  .middleware(Authorization) {}
