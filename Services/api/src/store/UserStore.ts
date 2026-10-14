import * as Cloudflare from "alchemy/Cloudflare";
import { Clock, Effect, Schema } from "effect";
import { applyMutations } from "./ChangeLog.ts";
import { type Entity, entities } from "./Entities.ts";
import { migrate, schemaVersion } from "./Migrations.ts";
import { fromDurableObjectStorage, type StoreSql } from "./StoreSql.ts";

export class UnknownEntity extends Schema.TaggedError<UnknownEntity>()("UnknownEntity", {
  entity: Schema.String,
}) {}

export class InvalidRow extends Schema.TaggedError<InvalidRow>()("InvalidRow", {
  entity: Schema.String,
  /** The position of the row in `upserts`. */
  index: Schema.Int,
  message: Schema.String,
}) {}

/**
 * A store's RPC methods over its database. The schema is brought up to date before any method can
 * run: here, when the object starts, and again after `deleteAll`.
 */
export const makeUserStore = (sql: StoreSql, registry: ReadonlyArray<Entity> = entities) => {
  migrate(sql);
  const entitiesByName = new Map(registry.map((entity) => [entity.name, entity]));
  return {
    /** The store's schema version, which can be newer than this code's after a rollback. */
    schemaVersion: () => Effect.sync(() => schemaVersion(sql)),
    /**
     * Deletes everything in the store, for account deletion, leaving it empty at the latest
     * schema. It's idempotent, so a call that fails partway can be retried.
     */
    deleteAll: () =>
      Effect.promise(() => sql.deleteAll()).pipe(Effect.andThen(Effect.sync(() => migrate(sql)))),
    /**
     * Upserts full rows of an entity and deletes records by ID, appending a change for each record
     * that changed (see `applyMutations`). Rows are validated first; one invalid row rejects the
     * whole call.
     */
    applyMutations: (
      entityName: string,
      upserts: ReadonlyArray<unknown>,
      deletes: ReadonlyArray<string>,
    ) =>
      Effect.gen(function* () {
        const entity = entitiesByName.get(entityName);
        if (entity === undefined) return yield* new UnknownEntity({ entity: entityName });
        const rows = yield* Effect.forEach(upserts, (row, index) =>
          Schema.decodeUnknownEffect(entity.row)(row).pipe(
            Effect.mapError(
              (error) => new InvalidRow({ entity: entityName, index, message: error.message }),
            ),
          ),
        );
        const at = yield* Clock.currentTimeMillis;
        return applyMutations(sql, entity, rows, deletes, at);
      }),
  };
};

export type UserStoreMethods = ReturnType<typeof makeUserStore>;

/**
 * One user's data, in a SQLite-backed Durable Object. Reach it through `UserStores`.
 *
 * It uses workerd's storage directly (`state.raw`), not Alchemy's wrapper, because writes must run
 * in a synchronous `transactionSync`. So it can't use Alchemy's alarm callbacks, which keep their
 * own bookkeeping in that wrapper.
 */
export class UserStore extends Cloudflare.DurableObject<UserStore>()(
  "UserStore",
  Effect.gen(function* () {
    const state = yield* Cloudflare.DurableObjectState;
    // A migration that fails stops the object from starting, rather than serving an old schema.
    return Effect.sync(() => makeUserStore(fromDurableObjectStorage(state.raw.storage)));
  }),
) {}
