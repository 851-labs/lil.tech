import * as Cloudflare from "alchemy/Cloudflare";
import { Clock, Effect } from "effect";
import {
  readHealthBatch,
  receiveHealthBatch,
  saveHealthBatch,
} from "../health/HealthBatchStore.ts";
import type { HealthBatch } from "../health/HealthBatches.ts";
import { applyMutations, readChanges } from "./ChangeLog.ts";
import { ChangesCompacted, InvalidMutation, type Mutation } from "./Changes.ts";
import type { Entity } from "./Entities.ts";
import { migrate, schemaVersion } from "./Migrations.ts";
import { entities } from "./Registry.ts";
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
    /** A page of the change log (see `readChanges`). */
    readChanges: (after: number, limit: number) =>
      Effect.suspend(() => {
        const page = readChanges(sql, after, limit);
        return page instanceof ChangesCompacted ? Effect.fail(page) : Effect.succeed(page);
      }),
    /** An uploaded health batch's status, or `null` if it was never received. */
    healthBatch: (id: string) => Effect.sync(() => readHealthBatch(sql, id)),
    /** Records a health batch as `queued` unless it's already known, and returns its status. */
    receiveHealthBatch: (id: string) =>
      Clock.currentTimeMillis.pipe(Effect.map((at) => receiveHealthBatch(sql, id, at))),
    saveHealthBatch: (batch: HealthBatch) => Effect.sync(() => saveHealthBatch(sql, batch)),
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
  { errors: [InvalidMutation, ChangesCompacted] },
) {}

export const UserStoreLive = UserStore.make(
  Effect.gen(function* () {
    const state = yield* Cloudflare.DurableObjectState;
    // A migration that fails stops the object from starting, rather than serving an old schema.
    return Effect.sync(() => makeUserStore(fromDurableObjectStorage(state.raw.storage)));
  }),
);
