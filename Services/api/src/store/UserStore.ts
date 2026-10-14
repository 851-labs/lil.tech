import * as Cloudflare from "alchemy/Cloudflare";
import { Clock, Effect } from "effect";
import { applyMutations, InvalidMutation, type Mutation } from "./ChangeLog.ts";
import { type Entity, entities } from "./Entities.ts";
import { migrate, schemaVersion } from "./Migrations.ts";
import { fromDurableObjectStorage, type StoreSql } from "./StoreSql.ts";

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
    /** Applies mutations in one transaction (see `applyMutations`). */
    applyMutations: (mutations: ReadonlyArray<Mutation>) =>
      Effect.gen(function* () {
        const at = yield* Clock.currentTimeMillis;
        return yield* Effect.suspend(() => {
          try {
            return Effect.succeed(applyMutations(sql, entitiesByName, mutations, at));
          } catch (error) {
            if (error instanceof InvalidMutation) return Effect.fail(error);
            throw error;
          }
        });
      }),
  };
};

export type UserStoreMethods = ReturnType<typeof makeUserStore>;

/**
 * One user's data, in a SQLite-backed Durable Object. Reach it through `UserStores`. Its errors
 * are declared so they cross RPC as instances of their classes, not plain objects.
 *
 * It uses workerd's storage directly (`state.raw`), not Alchemy's wrapper, because writes must run
 * in a synchronous `transactionSync`. So it can't use Alchemy's alarm callbacks, which keep their
 * own bookkeeping in that wrapper.
 */
export class UserStore extends Cloudflare.DurableObject<UserStore, UserStoreMethods>()(
  "UserStore",
  { errors: [InvalidMutation] },
) {}

export const UserStoreLive = UserStore.make(
  Effect.gen(function* () {
    const state = yield* Cloudflare.DurableObjectState;
    // A migration that fails stops the object from starting, rather than serving an old schema.
    return Effect.sync(() => makeUserStore(fromDurableObjectStorage(state.raw.storage)));
  }),
);
