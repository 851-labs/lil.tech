import { Effect, Schema } from "effect";
import { HttpApiEndpoint, HttpApiGroup } from "effect/http-api";
import { Authorization } from "../auth/AuthApi.ts";
import { documentQuery } from "../OpenApiAnnotations.ts";
import { ChangesCompacted, ChangesPage, Mutation, StorageFull } from "../store/Changes.ts";
import { UserStoreUnavailable } from "../store/UserStores.ts";

// The sync part of the API definition (`docs/SYNC.md`). Like `Api.ts`, it holds no server code.

export const maxChangesLimit = 5000;

const ChangesQuery = {
  /** The client's cursor: the `seq` of the last change it applied. 0 for nothing. */
  after: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))
    .annotate({ default: 0 })
    .pipe(Schema.withDecodingDefaultTypeKey(Effect.succeed(0))),
  /** How many changes to return. */
  limit: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: maxChangesLimit }))
    .annotate({ default: 1000 })
    .pipe(Schema.withDecodingDefaultTypeKey(Effect.succeed(1000))),
};

export const SnapshotPart = Schema.Struct({
  /** A short-lived (about 15 minutes) download URL that needs no `Authorization` header. */
  url: Schema.String,
  records: Schema.Int,
  bytes: Schema.Int,
  /** SHA-256 of the downloaded (gzip) bytes, hex. */
  sha256: Schema.String,
}).annotate({ identifier: "lil/api/sync/SnapshotPart" });

export const SnapshotManifest = Schema.Struct({
  id: Schema.String,
  /** Pull changes after this `seq` once the snapshot is loaded. */
  seq: Schema.Int,
  epoch: Schema.Int,
  /** When the snapshot started, in Unix milliseconds. */
  createdAt: Schema.Int,
  /** Each entity's records, in gzip NDJSON parts with one record per line. */
  entities: Schema.Array(
    Schema.Struct({ entity: Schema.String, parts: Schema.Array(SnapshotPart) }).annotate({
      identifier: "lil/api/sync/SnapshotEntity",
    }),
  ),
}).annotate({
  identifier: "lil/api/sync/SnapshotManifest",
  description: "A snapshot to bootstrap from",
});

export const LatestSnapshot = Schema.Struct({
  epoch: Schema.Int,
  /** Absent while the store has none yet: pull the whole log instead. */
  snapshot: Schema.optionalKey(SnapshotManifest),
}).annotate({ identifier: "lil/api/sync/LatestSnapshot" });

/**
 * The store's current epoch has no snapshot yet; it's being written. Retry after
 * `retryAfterSeconds`.
 */
export class SnapshotNotReady extends Schema.TaggedError<SnapshotNotReady>()(
  "SnapshotNotReady",
  { retryAfterSeconds: Schema.Int },
  { httpApiStatus: 503 },
) {}

/** The snapshot is gone (replaced over a week ago), or isn't the current epoch's. Start over. */
export class SnapshotGone extends Schema.TaggedError<SnapshotGone>()(
  "SnapshotGone",
  { id: Schema.String },
  { httpApiStatus: 410 },
) {}

/** The most mutations in one push. */
export const maxPushedMutations = 500;

export const PushMutations = Schema.Struct({
  /**
   * A UUID the client makes for this push. Pushing the same ID again within 7 days returns the
   * first push's result without applying anything, so retries are safe.
   */
  mutationId: Schema.String.check(
    Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
  ),
  /** Applied in order, in one transaction: all of them or none. */
  mutations: Schema.Array(Mutation).check(
    Schema.isMinLength(1),
    Schema.isMaxLength(maxPushedMutations),
  ),
}).annotate({ identifier: "lil/api/sync/PushMutations" });

export const PushedMutations = Schema.Struct({
  /** The `seq` of the last change the push made, or `head` if it changed nothing. */
  seq: Schema.Int,
}).annotate({ identifier: "lil/api/sync/PushedMutations" });

/**
 * A mutation can never be applied: its entity isn't one apps may write, or its row is invalid.
 * Nothing in the push was applied, and retrying won't help.
 */
export class MutationRejected extends Schema.TaggedError<MutationRejected>()(
  "MutationRejected",
  {
    /** The mutation's position in the push. */
    index: Schema.Int,
    message: Schema.String,
  },
  { httpApiStatus: 400 },
) {}

export class SyncApi extends HttpApiGroup.make("sync")
  .add(
    HttpApiEndpoint.get("changes", "/v1/sync/changes", {
      query: ChangesQuery,
      success: ChangesPage,
      error: [ChangesCompacted, UserStoreUnavailable],
    }).annotateMerge(documentQuery(ChangesQuery)),
  )
  .add(
    // The store's current epoch and its latest snapshot, to bootstrap a new device from.
    HttpApiEndpoint.get("snapshot", "/v1/sync/snapshot", {
      success: LatestSnapshot,
      error: [SnapshotNotReady, UserStoreUnavailable],
    }),
  )
  .add(
    // Writes from apps, to entities they may write such as `health_pin` (`docs/SYNC.md`).
    HttpApiEndpoint.post("pushMutations", "/v1/sync/mutations", {
      payload: PushMutations,
      success: PushedMutations,
      error: [MutationRejected, StorageFull, UserStoreUnavailable],
    }),
  )
  .add(
    // A snapshot by ID with fresh part URLs, for a client whose URLs expired mid-download.
    HttpApiEndpoint.get("snapshotById", "/v1/sync/snapshots/:id", {
      params: { id: Schema.String.check(Schema.isMaxLength(64)) },
      success: SnapshotManifest,
      error: [SnapshotGone, UserStoreUnavailable],
    }),
  )
  .middleware(Authorization) {}
