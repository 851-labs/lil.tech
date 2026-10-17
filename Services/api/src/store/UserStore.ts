import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Clock, Effect } from "effect";
import { HttpServerRequest, HttpServerResponse } from "effect/http";
import {
  readHealthBatch,
  receiveHealthBatch,
  saveHealthBatch,
} from "../health/HealthBatchStore.ts";
import type { HealthBatch } from "../health/HealthBatches.ts";
import { deleteObjects, listObjects, provideRuntime } from "../Runtime.ts";
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
import {
  deviceSignedOut,
  hasRetiringDevices,
  markRetired,
  retiredAmong,
  retireStep,
  retireStepInterval,
} from "./RetiredDevices.ts";
import { fromDurableObjectStorage, type StoreSql } from "./StoreSql.ts";
import {
  type BlobFiles,
  nextBlobSweepAt,
  noBlobFiles,
  retryBlobSweepLater,
  sweepBlobs,
} from "./BlobSweep.ts";

/**
 * How large a store's database may grow before it takes no new uploads: below the 10 GB a Durable
 * Object can hold (`docs/DECISIONS.md`). The size counts used pages only, so deleted records
 * make room once the change log is compacted.
 */
export const storageQuotaBytes = 8 * 1024 ** 3;

/**
 * Past this, writes of new records fail too. Uploads stop at the quota, but batches accepted
 * before it are still applied (the iPhone doesn't send a batch again once it's accepted), so the
 * gap up to the 10 GB cap absorbs them.
 */
export const storageHardLimitBytes = 9.5 * 1024 ** 3;

const readHealthBlobSize = (sql: StoreSql, sha256: string): number | null => {
  const row = sql.exec("SELECT size FROM health_blobs WHERE sha256 = ?", sha256)[0];
  return row === undefined ? null : Number(row["size"]);
};

const recordHealthBlob = (
  sql: StoreSql,
  sha256: string,
  size: number,
  prefix: string,
  at: number,
) =>
  sql.transaction(() => {
    sql.exec(
      `INSERT INTO meta (key, value) VALUES ('health_blob_prefix', ?) ON CONFLICT (key) DO NOTHING`,
      prefix,
    );
    if (readHealthBlobSize(sql, sha256) !== null) return;
    // A first sweep a day from now, not at once.
    sql.exec(
      `INSERT INTO meta (key, value) VALUES ('health_blob_swept_at', ?)
       ON CONFLICT (key) DO NOTHING`,
      at,
    );
    sql.exec(
      "INSERT INTO health_blobs (sha256, size, uploaded_at) VALUES (?, ?, ?)",
      sha256,
      size,
      at,
    );
    sql.exec(
      `INSERT INTO meta (key, value) VALUES ('health_blob_bytes', ?)
       ON CONFLICT (key) DO UPDATE SET value = value + excluded.value`,
      size,
    );
  });

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
  blobFiles: BlobFiles = noBlobFiles,
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

  /** What counts towards the quota: the database, and the health blobs in R2. */
  const storageBytes = () => sql.databaseSize() + readMeta(sql, "health_blob_bytes", 0);
  /** Fails once the store's database reaches `limit`. */
  const ensureRoom = (limit: number) =>
    Effect.suspend(() =>
      sql.databaseSize() >= limit
        ? Effect.fail(new StorageFull({ quotaBytes: storageQuotaBytes }))
        : Effect.void,
    );
  /** Fails once the account's storage, blobs included, reaches its quota. */
  const ensureQuota = Effect.suspend(() =>
    storageBytes() >= storageQuotaBytes
      ? Effect.fail(new StorageFull({ quotaBytes: storageQuotaBytes }))
      : Effect.void,
  );
  const healthBatch = (id: string) =>
    ensureNotDeleted.pipe(
      Effect.andThen(Clock.currentTimeMillis),
      Effect.map((now) => readHealthBatch(sql, id, now)),
    );

  const isRetired = (device: string) => retiredAmong(sql, new Set([device])).size > 0;
  /** Whether a retired device still has records to delete, kept so writes don't have to ask. */
  let retiring = hasRetiringDevices(sql);

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
    const retireAt = retiring ? now + retireStepInterval : null;
    const times = [nextAlarmAt(sql, now), expiry, retireAt, nextBlobSweepAt(sql)].filter(
      (time): time is number => time !== null,
    );
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
    /**
     * Retires a device that signed out for good: its device-scoped records are deleted over the
     * next alarms (`src/store/RetiredDevices.ts`), and it can't write any again. Idempotent.
     */
    retireDevice: (device: string) =>
      Effect.gen(function* () {
        yield* ensureNotDeleted;
        const now = yield* Clock.currentTimeMillis;
        markRetired(sql, device, now);
        retiring = true;
        yield* scheduleAlarm(now);
      }),
    /** Whether a device was retired, so its records are refused. */
    isRetired: (device: string) => Effect.sync(() => isRetired(device)),
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
    healthBatch,
    /**
     * Before a health batch is uploaded: its status if it's already known, otherwise `null`, or
     * `StorageFull` once the store has reached its quota.
     */
    checkHealthBatchUpload: (id: string) =>
      healthBatch(id).pipe(Effect.tap((known) => (known === null ? ensureQuota : Effect.void))),
    /** The database's size plus the health blobs', which `storageQuotaBytes` limits. */
    storageBytes: () => Effect.sync(storageBytes),
    /** A health blob's size, or `null` if this user never uploaded it. */
    healthBlobSize: (sha256: string) =>
      ensureNotDeleted.pipe(Effect.map(() => readHealthBlobSize(sql, sha256))),
    /**
     * Before a health blob is uploaded: its size if it's already stored, otherwise `null`, or
     * `StorageFull` once the account has reached its quota.
     */
    checkHealthBlobUpload: (sha256: string) =>
      ensureNotDeleted.pipe(
        Effect.map(() => {
          const known = readHealthBlobSize(sql, sha256);
          // Uploading it again means a record is about to refer to it: it isn't swept yet.
          if (known !== null) {
            sql.exec("UPDATE health_blobs SET unreferenced_since = NULL WHERE sha256 = ?", sha256);
          }
          return known;
        }),
        Effect.tap((known) => (known === null ? ensureQuota : Effect.void)),
      ),
    /**
     * Records a health blob once it's in R2 under `prefix` (the user's, the same for every blob),
     * counting it towards the quota. Idempotent.
     */
    recordHealthBlob: (sha256: string, size: number, prefix: string) =>
      Effect.gen(function* () {
        yield* ensureNotDeleted;
        const at = yield* Clock.currentTimeMillis;
        recordHealthBlob(sql, sha256, size, prefix, at);
        // The first blob schedules the daily sweep.
        yield* scheduleAlarm(at);
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
     * Before a queued health batch is applied, in one call: a batch that's already `applied` or
     * `failed` is returned as it is, to be skipped. Otherwise it's marked `applying` and returned,
     * with whether `device` (the uploading device, if known) was retired.
     */
    beginHealthBatch: (id: string, device?: string) =>
      ensureNotDeleted.pipe(
        Effect.andThen(Clock.currentTimeMillis),
        Effect.map((at) => {
          const known = readHealthBatch(sql, id, at);
          if (known?.status === "applied" || known?.status === "failed") {
            return { batch: known, deviceRetired: false };
          }
          const batch: HealthBatch = {
            id,
            status: "applying",
            receivedAt: known?.receivedAt ?? at,
          };
          saveHealthBatch(sql, batch, at);
          return { batch, deviceRetired: device !== undefined && isRetired(device) };
        }),
      ),
    /** Records a health batch's outcome, and returns the storage the account now takes. */
    finishHealthBatch: (batch: HealthBatch) =>
      ensureNotDeleted.pipe(
        Effect.andThen(Clock.currentTimeMillis),
        Effect.map((at) => {
          saveHealthBatch(sql, batch, at);
          return storageBytes();
        }),
      ),
    /**
     * Applies mutations in one transaction (see `applyMutations`). Past `storageHardLimitBytes`,
     * only deletes are applied: a call with an upsert fails with `StorageFull`.
     */
    applyMutations: (mutations: ReadonlyArray<Mutation>) =>
      Effect.gen(function* () {
        yield* ensureNotDeleted;
        if (mutations.some((mutation) => mutation.op === "upsert")) {
          yield* ensureRoom(storageHardLimitBytes);
        }
        // A retired device's records are deleted, and mustn't come back. Ingestion drops them
        // first (`beginHealthBatch`), so this is a backstop.
        const deviceOf = (mutation: Mutation) =>
          mutation.op === "upsert" &&
          entitiesByName.get(mutation.entity)?.deviceScoped !== undefined &&
          typeof mutation.row["device"] === "string"
            ? mutation.row["device"]
            : undefined;
        const retired = retiredAmong(
          sql,
          new Set(mutations.map(deviceOf).filter((device) => device !== undefined)),
        );
        const index = mutations.findIndex((mutation) => {
          const device = deviceOf(mutation);
          return device !== undefined && retired.has(device);
        });
        if (index !== -1) {
          return yield* new InvalidMutation({ index, message: deviceSignedOut });
        }
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
        const sweepAt = nextBlobSweepAt(sql);
        if (sweepAt !== null && sweepAt <= now) {
          // Its failure doesn't hold up the rest of the alarm, and it's tried again in an hour.
          yield* sweepBlobs(sql, registry, blobFiles, now).pipe(
            Effect.catchCause((cause) =>
              Effect.gen(function* () {
                yield* Effect.logWarning("Blob sweep failed", cause);
                retryBlobSweepLater(sql, now);
              }),
            ),
          );
        }
        if (retiring) {
          if (retireStep(sql, registry, now) > 0) yield* notices.notify(now);
          retiring = hasRetiringDevices(sql);
        }
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
 * Every error a store's methods fail with. Only these cross RPC as instances of their classes;
 * any other arrives as a plain object, which the API can't encode (a 500).
 */
export const userStoreErrors = [InvalidMutation, ChangesCompacted, AccountDeleted, StorageFull];

/**
 * One user's data, in a SQLite-backed Durable Object. Reach it through `UserStores`. Its errors
 * are declared so they cross RPC as instances of their classes, not plain objects.
 *
 * It uses workerd's storage directly (`state.raw`), not Alchemy's wrapper, because writes must run
 * in a synchronous `transactionSync`. So it can't use Alchemy's alarm callbacks, which keep their
 * own bookkeeping in that wrapper.
 */
export class UserStore extends Cloudflare.DurableObject<UserStore, UserStoreShape>()("UserStore", {
  errors: userStoreErrors,
}) {}

/** Snapshot parts (`src/store/Snapshots.ts`). */
export const SnapshotBucket = Cloudflare.R2.Bucket("SyncSnapshots");
/**
 * Health blobs (`src/health/HealthBlobs.ts`), under `health-blobs/<user>/<sha256>`. Immutable;
 * the store sweeps the ones no record refers to any more (`src/store/BlobSweep.ts`).
 */
export const HealthBlobBucket = Cloudflare.R2.Bucket("HealthBlobs");

export const UserStoreLive = UserStore.make(
  Effect.gen(function* () {
    const state = yield* Cloudflare.DurableObjectState;
    const bucket = yield* Cloudflare.R2.ReadWriteBucket(yield* SnapshotBucket);
    const blobBucket = yield* Cloudflare.R2.ReadWriteBucket(yield* HealthBlobBucket);
    return Effect.gen(function* () {
      // The bucket's and sockets' calls need the object's runtime context, which exists from
      // here on.
      const inRuntime = provideRuntime(yield* Alchemy.RuntimeContext);
      const files: SnapshotFiles = {
        put: (key, bytes) =>
          inRuntime(
            bucket.put(key, bytes, { httpMetadata: { contentType: "application/gzip" } }),
          ).pipe(Effect.asVoid, Effect.orDie),
        delete: (keys) => deleteObjects(bucket, keys).pipe(inRuntime, Effect.orDie),
      };
      const blobFiles: BlobFiles = {
        list: (prefix) => listObjects(blobBucket, prefix).pipe(inRuntime, Effect.orDie),
        delete: (keys) => deleteObjects(blobBucket, keys).pipe(inRuntime, Effect.orDie),
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
        blobFiles,
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
