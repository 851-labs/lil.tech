import { Schema } from "effect";

// The change log's wire types and errors (`docs/SYNC.md`), shared by the store and the API
// definition. Responses only grow: clients skip ops, entities and fields they don't know.

/** One write to a store, as clients push it (`docs/SYNC.md`). */
export const Mutation = Schema.Union([
  Schema.Struct({
    entity: Schema.String,
    op: Schema.Literal("upsert"),
    id: Schema.NonEmptyString,
    /** The fields to set. Missing fields keep their stored values, and `null` clears one. */
    row: Schema.Record(Schema.String, Schema.Json),
  }),
  Schema.Struct({
    entity: Schema.String,
    op: Schema.Literal("delete"),
    id: Schema.NonEmptyString,
  }),
]);
export type Mutation = typeof Mutation.Type;

/** A mutation can never be applied, e.g. its row is invalid. Retrying won't help. */
export class InvalidMutation extends Schema.TaggedError<InvalidMutation>()("InvalidMutation", {
  /** The mutation's position in the call. */
  index: Schema.Int,
  message: Schema.String,
}) {}

export const Change = Schema.Struct({
  /** Position in the log, increasing by exactly 1 per change. */
  seq: Schema.Int,
  entity: Schema.String,
  id: Schema.String,
  /** `upsert` or `delete`. Clients skip ops they don't know, so more can be added. */
  op: Schema.String,
  /**
   * The whole record after an upsert, with `camelCase` fields. Absent for deletes. Its values
   * aren't checked again on the way out: the store validated them when it wrote them.
   */
  row: Schema.optionalKey(Schema.Record(Schema.String, Schema.Unknown)),
  /** When the change was written, in Unix milliseconds. */
  at: Schema.Int,
}).annotate({ identifier: "lil/api/sync/Change", description: "One entry of the change log" });
export type Change = typeof Change.Type;

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
export type ChangesPage = typeof ChangesPage.Type;

/** The changes after the cursor were compacted away. The client bootstraps from a snapshot. */
export class ChangesCompacted extends Schema.TaggedError<ChangesCompacted>()(
  "ChangesCompacted",
  /** Why the client must bootstrap, e.g. `compacted`. */
  { reason: Schema.String },
  { httpApiStatus: 410 },
) {}
