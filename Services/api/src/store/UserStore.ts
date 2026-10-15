import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Array as Arr, Clock, Effect } from "effect";
import { HttpServerRequest, HttpServerResponse } from "effect/http";
import {
  readHealthBatch,
  receiveHealthBatch,
  saveHealthBatch,
} from "../health/HealthBatchStore.ts";
import type { HealthBatch } from "../health/HealthBatches.ts";
import { provideRuntime } from "../Runtime.ts";
import { applyMutations, readChanges, readEpoch, readHead, readMeta } from "./ChangeLog.ts";
import {
  AccountDeleted,
  ChangesCompacted,
  InvalidMutation,
  type Mutation,
  StorageFull,
} from "./Changes.ts";
import type { Entity } from "./Entities.ts";
import {
  answerCloseCode,
  headNotice,
  type LiveSocket,
  type LiveSockets,
  makeLiveNotices,
  noLiveSockets,
  sessionExpiresHeader,
} from "./LiveNotices.ts";
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

/**
 * How large a store's database may grow before it takes no new records: below the 10 GB a Durable
 * Object can hold, leaving room for the change log and upkeep (`docs/DECISIONS.md`).
 */
export const storageQuotaBytes = 8 * 1024 ** 3;

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
  sockets: LiveSockets = noLiveSockets,
) => {
  migrate(sql);
  const notices = makeLiveNotices(sockets, () => readHead(sql));
  const entitiesByName = new Map(registry.map((entity) => [entity.name, entity]));

  /** Whether the account was deleted; only `deleteAll` sets it, and this object is its writer. */
  let deleted = readMeta(sql, "deleted", 0) === 1;
  /** Fails once the account is deleted, so nothing can be read or written back. */
  const ensureNotDeleted = Effect.suspend(() =>
    deleted ? Effect.fail(new AccountDeleted()) : Effect.void,
  );

  /** Fails once the store is over its quota, so it takes no new records. */
  const ensureRoom = Effect.suspend(() =>
    sql.databaseSize() >= storageQuotaBytes
      ? Effect.fail(new StorageFull({ quotaBytes: storageQuotaBytes }))
      : Effect.void,
  );

  /** When the alarm is set for, once known, so most writes don't have to ask. */
  let alarmAt: number | null | undefined;
  /**
   * Moves the alarm earlier if snapshot work or upkeep is due sooner than it's set for. Never
   * sets it for `now`: the alarm running at that time would be cleared when it finishes.
   */
  const scheduleAlarm = Effect.fnUntraced(function* (
    now: number,
    options: { readonly afterAlarm?: boolean; readonly sockets?: boolean } = {},
  ) {
    // Socket expiries only change when a client connects and when the alarm runs, so writes
    // skip listing the sockets: an alarm already set for an expiry is never moved later.
    const expiry = options.sockets === true ? yield* notices.nextExpiry : null;
    const times = [nextAlarmAt(sql, now), expiry].filter((time): time is number => time !== null);
    if (times.length === 0) return;
    const due = Math.min(...times);
    // Right after the alarm ran, it's spent, whatever the runtime still reports.
    if (options.afterAlarm !== true) {
      alarmAt ??= yield* Effect.promise(() => sql.getAlarm());
      if (alarmAt !== null && alarmAt <= due) return;
    }
    const at = Math.max(due, now + 1);
    yield* Effect.promise(() => sql.setAlarm(at));
    alarmAt = at;
  });

  return {
    /** The store's schema version, which can be newer than this code's after a rollback. */
    schemaVersion: () => Effect.sync(() => schemaVersion(sql)),
    /**
     * Deletes everything in the store and its snapshot files, for account deletion, leaving it
     * empty at the latest schema and marked deleted: writes fail with `AccountDeleted` from then
     * on (user IDs are never reused). It's idempotent, so a call that fails partway can be
     * retried.
     */
    deleteAll: () =>
      Effect.gen(function* () {
        yield* files.delete(allSnapshotKeys(sql));
        yield* Effect.promise(() => sql.deleteAll());
        alarmAt = null;
        migrate(sql);
        sql.exec("INSERT INTO meta (key, value) VALUES ('deleted', 1)");
        deleted = true;
        // Connected clients see `head` go back to 0 and start over; their sockets still close
        // when their tokens expire.
        const now = yield* Clock.currentTimeMillis;
        yield* notices.announce(now);
        yield* scheduleAlarm(now, { sockets: true });
      }),
    /** A page of the change log (see `readChanges`). */
    readChanges: (after: number, limit: number) =>
      Effect.suspend(() => {
        const page = readChanges(sql, after, limit);
        return page instanceof ChangesCompacted ? Effect.fail(page) : Effect.succeed(page);
      }),
    /** An uploaded health batch's status, or `null` if it was never received. */
    healthBatch: (id: string) =>
      ensureNotDeleted.pipe(
        Effect.andThen(Clock.currentTimeMillis),
        Effect.map((now) => readHealthBatch(sql, id, now)),
      ),
    /**
     * Before a health batch is uploaded: its status if it's already known, otherwise `null`, or
     * `StorageFull` if the store can't take a new batch.
     */
    checkHealthBatchUpload: (id: string) =>
      Effect.gen(function* () {
        yield* ensureNotDeleted;
        const known = readHealthBatch(sql, id, yield* Clock.currentTimeMillis);
        if (known === null) yield* ensureRoom;
        return known;
      }),
    /** Records a health batch as `queued` unless it's already known, and returns its status. */
    receiveHealthBatch: (id: string) =>
      ensureNotDeleted.pipe(
        Effect.andThen(Clock.currentTimeMillis),
        Effect.map((at) => receiveHealthBatch(sql, id, at)),
      ),
    saveHealthBatch: (batch: HealthBatch) =>
      ensureNotDeleted.pipe(
        Effect.andThen(Clock.currentTimeMillis),
        Effect.map((at) => saveHealthBatch(sql, batch, at)),
      ),
    /**
     * Applies mutations in one transaction (see `applyMutations`). Over the quota, only deletes
     * are applied: a call with an upsert fails with `StorageFull`.
     */
    applyMutations: (mutations: ReadonlyArray<Mutation>) =>
      Effect.gen(function* () {
        yield* ensureNotDeleted;
        if (mutations.some((mutation) => mutation.op === "upsert")) yield* ensureRoom;
        const at = yield* Clock.currentTimeMillis;
        const applied = yield* Effect.suspend(() => {
          try {
            return Effect.succeed(applyMutations(sql, entitiesByName, mutations, at));
          } catch (error) {
            if (error instanceof InvalidMutation) return Effect.fail(error);
            throw error;
          }
        });
        if (applied.appended > 0) {
          yield* notices.notify(at);
          yield* scheduleAlarm(at);
        }
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
    /**
     * Greets a client that just connected for live notices with the current `head`, and makes
     * sure the alarm closes its socket when its token expires.
     */
    liveConnected: (socket: LiveSocket) =>
      Effect.gen(function* () {
        yield* socket.send(headNotice(readHead(sql)));
        yield* scheduleAlarm(yield* Clock.currentTimeMillis, { sockets: true });
      }),
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
        yield* notices.closeExpired(now);
        yield* writeSnapshotStep(sql, registry, files, now);
        yield* doUpkeep(sql, files, now);
        yield* scheduleAlarm(now, { afterAlarm: true, sockets: true });
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

/** A store as a Durable Object: its RPC methods, plus live connections. */
export type UserStoreShape = UserStoreMethods & {
  /** Accepts a live notice connection the Worker forwarded (`GET /v1/sync/live`). */
  readonly fetch: Effect.Effect<
    HttpServerResponse.HttpServerResponse,
    never,
    HttpServerRequest.HttpServerRequest | Cloudflare.DurableObjectState | Alchemy.RuntimeContext
  >;
  readonly webSocketClose: (
    socket: Cloudflare.WebSocket,
    code: number,
    reason: string,
  ) => Effect.Effect<void>;
};

/**
 * One user's data, in a SQLite-backed Durable Object. Reach it through `UserStores`. Its errors
 * are declared so they cross RPC as instances of their classes, not plain objects.
 *
 * It uses workerd's storage directly (`state.raw`), not Alchemy's wrapper, because writes must run
 * in a synchronous `transactionSync`. So it can't use Alchemy's alarm callbacks, which keep their
 * own bookkeeping in that wrapper.
 */
export class UserStore extends Cloudflare.DurableObject<UserStore, UserStoreShape>()("UserStore", {
  errors: [InvalidMutation, ChangesCompacted, AccountDeleted],
}) {}

/** Snapshot parts (`src/store/Snapshots.ts`). */
export const SnapshotBucket = Cloudflare.R2.Bucket("SyncSnapshots");

export const UserStoreLive = UserStore.make(
  Effect.gen(function* () {
    const state = yield* Cloudflare.DurableObjectState;
    const bucket = yield* Cloudflare.R2.ReadWriteBucket(yield* SnapshotBucket);
    return Effect.gen(function* () {
      // The bucket's and sockets' calls need the object's runtime context, which exists from
      // here on.
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
      type Attachment = { readonly expiresAt?: number; readonly closed?: boolean } | null;
      const attachment = (socket: Cloudflare.WebSocket) =>
        socket.deserializeAttachment() as Attachment;
      const toLiveSocket = (socket: Cloudflare.WebSocket): LiveSocket => ({
        send: (text) => socket.send(text),
        // The runtime lists a socket until the client acknowledges the close, so it's marked.
        close: (code, reason) =>
          Effect.sync(() =>
            socket.serializeAttachment({ ...attachment(socket), closed: true }),
          ).pipe(Effect.andThen(socket.close(code, reason))),
        expiresAt: attachment(socket)?.expiresAt ?? 0,
      });
      const sockets: LiveSockets = {
        // Listed from the runtime each time, so sockets survive the object hibernating.
        list: inRuntime(state.getWebSockets()).pipe(
          Effect.map((all) =>
            all
              .filter((socket) => socket.ws.readyState === 1 && attachment(socket)?.closed !== true)
              .map(toLiveSocket),
          ),
        ),
        later: (delayMs, task) => {
          setTimeout(() => Effect.runFork(task), delayMs);
        },
      };
      // Keep-alive pings are answered by the runtime without waking the object.
      yield* state.setWebSocketAutoResponse(
        new (
          globalThis as unknown as {
            WebSocketRequestResponsePair: new (request: string, response: string) => never;
          }
        ).WebSocketRequestResponsePair("ping", "pong"),
      );
      // A migration that fails stops the object from starting, rather than serving an old schema.
      const store = makeUserStore(
        fromDurableObjectStorage(state.raw.storage),
        entities,
        files,
        sockets,
      );
      return {
        ...store,
        fetch: Effect.gen(function* () {
          const request = yield* HttpServerRequest.HttpServerRequest;
          const expiresAt = Number(request.headers[sessionExpiresHeader]);
          if (!Number.isFinite(expiresAt)) return HttpServerResponse.empty({ status: 400 });
          const [response, socket] = yield* Cloudflare.upgrade();
          socket.serializeAttachment({ expiresAt });
          yield* store.liveConnected(toLiveSocket(socket));
          return response;
        }),
        webSocketClose: (socket, code, reason) =>
          socket
            .close(answerCloseCode(code), reason)
            .pipe(Effect.catchCause((cause) => Effect.logDebug("Closing a socket failed", cause))),
      } satisfies UserStoreShape;
    });
  }).pipe(Effect.provide(Cloudflare.R2.ReadWriteBucketBinding)),
);
