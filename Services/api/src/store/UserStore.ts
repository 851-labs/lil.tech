import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Array as Arr, Clock, Effect } from "effect";
import {
  readHealthBatch,
  receiveHealthBatch,
  saveHealthBatch,
} from "../health/HealthBatchStore.ts";
import type { HealthBatch } from "../health/HealthBatches.ts";
import { provideRuntime } from "../Runtime.ts";
import { applyMutations, readChanges, readEpoch } from "./ChangeLog.ts";
import { ChangesCompacted, InvalidMutation, type Mutation } from "./Changes.ts";
import type { Entity } from "./Entities.ts";
import { migrate, schemaVersion } from "./Migrations.ts";
import {
  allSnapshotKeys,
  doUpkeep,
  latestSnapshot,
  nextAlarmAt,
  readSnapshot,
  type SnapshotFiles,
  writeSnapshotStep,
} from "./Snapshots.ts";
import { entities } from "./Registry.ts";
import { fromDurableObjectStorage, type StoreSql } from "./StoreSql.ts";

/** Snapshot files that aren't available, for stores built without them (most tests). */
const noSnapshotFiles: SnapshotFiles = {
  put: () => Effect.die("This store has no snapshot files"),
  delete: () => Effect.void,
};

/**
 * A store's RPC methods over its database. The schema is brought up to date before any method can
 * run: here, when the object starts, and again after `deleteAll`.
 */
export const makeUserStore = (
  sql: StoreSql,
  registry: ReadonlyArray<Entity> = entities,
  files: SnapshotFiles = noSnapshotFiles,
) => {
  migrate(sql);
  const entitiesByName = new Map(registry.map((entity) => [entity.name, entity]));

  /** When the alarm is set for, once known, so most writes don't have to ask. */
  let alarmAt: number | null | undefined;
  /**
   * Moves the alarm earlier if snapshot work or upkeep is due sooner than it's set for. Never
   * sets it for `now`: the alarm running at that time would be cleared when it finishes.
   */
  const scheduleAlarm = Effect.fnUntraced(function* (now: number) {
    const due = nextAlarmAt(sql, now);
    if (due === null) return;
    alarmAt ??= yield* Effect.promise(() => sql.getAlarm());
    if (alarmAt !== null && alarmAt <= due) return;
    const at = Math.max(due, now + 1);
    yield* Effect.promise(() => sql.setAlarm(at));
    alarmAt = at;
  });

  return {
    /** The store's schema version, which can be newer than this code's after a rollback. */
    schemaVersion: () => Effect.sync(() => schemaVersion(sql)),
    /**
     * Deletes everything in the store and its snapshot files, for account deletion, leaving it
     * empty at the latest schema. It's idempotent, so a call that fails partway can be retried.
     */
    deleteAll: () =>
      Effect.gen(function* () {
        yield* files.delete(allSnapshotKeys(sql));
        yield* Effect.promise(() => sql.deleteAll());
        alarmAt = null;
        migrate(sql);
      }),
    /** A page of the change log (see `readChanges`). */
    readChanges: (after: number, limit: number) =>
      Effect.suspend(() => {
        const page = readChanges(sql, after, limit);
        return page instanceof ChangesCompacted ? Effect.fail(page) : Effect.succeed(page);
      }),
    /** An uploaded health batch's status, or `null` if it was never received. */
    healthBatch: (id: string) =>
      Clock.currentTimeMillis.pipe(Effect.map((now) => readHealthBatch(sql, id, now))),
    /** Records a health batch as `queued` unless it's already known, and returns its status. */
    receiveHealthBatch: (id: string) =>
      Clock.currentTimeMillis.pipe(Effect.map((at) => receiveHealthBatch(sql, id, at))),
    saveHealthBatch: (batch: HealthBatch) =>
      Clock.currentTimeMillis.pipe(Effect.map((at) => saveHealthBatch(sql, batch, at))),
    /** Applies mutations in one transaction (see `applyMutations`). */
    applyMutations: (mutations: ReadonlyArray<Mutation>) =>
      Effect.gen(function* () {
        const at = yield* Clock.currentTimeMillis;
        const applied = yield* Effect.suspend(() => {
          try {
            return Effect.succeed(applyMutations(sql, entitiesByName, mutations, at));
          } catch (error) {
            if (error instanceof InvalidMutation) return Effect.fail(error);
            throw error;
          }
        });
        if (applied.appended > 0) yield* scheduleAlarm(at);
        return applied;
      }),
    /**
     * What a new device bootstraps from, read together so they agree: the store's epoch, whether
     * it ever compacted, and its latest snapshot of that epoch.
     */
    bootstrap: () =>
      Effect.sync(() =>
        sql.transaction(() => ({
          epoch: readEpoch(sql),
          snapshot: latestSnapshot(sql),
        })),
      ),
    /** The latest published snapshot of the current epoch, or `null`. */
    latestSnapshot: () => Effect.sync(() => latestSnapshot(sql)),
    /** A published snapshot of the current epoch by ID, or `null` (see `readSnapshot`). */
    snapshot: (id: string) => Effect.sync(() => readSnapshot(sql, id)),
    /**
     * The store's alarm: one step of snapshot work and any upkeep that's due, then the alarm is
     * set for whatever is next. A failed step is retried a minute later.
     */
    alarm: () =>
      Effect.gen(function* () {
        alarmAt = null;
        const now = yield* Clock.currentTimeMillis;
        yield* writeSnapshotStep(sql, registry, files, now);
        yield* doUpkeep(sql, files, now);
        yield* scheduleAlarm(now);
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.gen(function* () {
            yield* Effect.logWarning("Snapshot step failed", cause);
            const now = yield* Clock.currentTimeMillis;
            yield* Effect.promise(() => sql.setAlarm(now + 60_000));
            alarmAt = now + 60_000;
          }),
        ),
      ),
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

/** Snapshot parts (`src/store/Snapshots.ts`). */
export const SnapshotBucket = Cloudflare.R2.Bucket("SyncSnapshots");

export const UserStoreLive = UserStore.make(
  Effect.gen(function* () {
    const state = yield* Cloudflare.DurableObjectState;
    const bucket = yield* Cloudflare.R2.ReadWriteBucket(yield* SnapshotBucket);
    return Effect.gen(function* () {
      // The bucket's calls need the object's runtime context, which exists from here on.
      const inRuntime = provideRuntime(yield* Alchemy.RuntimeContext);
      const files: SnapshotFiles = {
        put: (key, bytes) =>
          inRuntime(
            bucket.put(key, bytes, { httpMetadata: { contentType: "application/gzip" } }),
          ).pipe(Effect.asVoid, Effect.orDie),
        // R2 deletes at most 1,000 keys per call.
        delete: (keys) =>
          Effect.forEach(
            Arr.chunksOf(keys, 1000),
            (chunk) => inRuntime(bucket.delete([...chunk])),
            {
              discard: true,
            },
          ).pipe(Effect.orDie),
      };
      // A migration that fails stops the object from starting, rather than serving an old schema.
      return makeUserStore(fromDurableObjectStorage(state.raw.storage), entities, files);
    });
  }).pipe(Effect.provide(Cloudflare.R2.ReadWriteBucketBinding)),
);
