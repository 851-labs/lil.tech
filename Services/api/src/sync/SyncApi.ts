import { Effect, Schema } from "effect";
import { HttpApiEndpoint, HttpApiGroup } from "effect/http-api";
import { Authorization } from "../auth/AuthApi.ts";
import { documentQuery } from "../OpenApiAnnotations.ts";
import { ChangesCompacted, ChangesPage } from "../store/Changes.ts";
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

export class SyncApi extends HttpApiGroup.make("sync")
  .add(
    HttpApiEndpoint.get("changes", "/v1/sync/changes", {
      query: ChangesQuery,
      success: ChangesPage,
      error: [ChangesCompacted, UserStoreUnavailable],
    }).annotateMerge(documentQuery(ChangesQuery)),
  )
  .middleware(Authorization) {}
