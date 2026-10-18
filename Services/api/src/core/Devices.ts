import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { and, eq, exists, gt, isNull, lt, notExists, type SQLWrapper } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, first, query } from "./CoreDb.ts";
import { DeviceId, newDeviceId, UserId } from "./Ids.ts";
import { devices, sessions } from "./Schema.ts";

export const DevicePlatform = Schema.Literals(["ios", "macos"]);
export type DevicePlatform = typeof DevicePlatform.Type;

/** An app install that signs in, e.g. lil health on someone's iPhone. */
export class Device extends Schema.Class<Device>("lil/api/core/Device")({
  id: DeviceId,
  userId: UserId,
  /** Which app, e.g. `health-ios` or `health-mac`. */
  app: Schema.NonEmptyString,
  platform: DevicePlatform,
  name: Schema.NullOr(Schema.String),
  pushToken: Schema.NullOr(Schema.String),
  createdAt: Schema.Number,
  lastSeenAt: Schema.Number,
}) {}

const decodeDevice = (row: unknown) => Schema.decodeUnknownEffect(Device)(row).pipe(Effect.orDie);

export class Devices extends Context.Service<
  Devices,
  {
    readonly create: (input: {
      readonly userId: UserId;
      readonly app: string;
      readonly platform: DevicePlatform;
      readonly name: string | null;
    }) => Effect.Effect<Device, SqlError.SqlError | Schema.SchemaError>;
    readonly findById: (id: DeviceId) => Effect.Effect<Option.Option<Device>, SqlError.SqlError>;
    readonly listForUser: (
      userId: UserId,
    ) => Effect.Effect<ReadonlyArray<Device>, SqlError.SqlError>;
    /**
     * The user's devices that are signed in: with a session that's neither revoked nor expired at
     * `now`. A device whose sessions all expired keeps its row, so `listForUser` has those too.
     */
    readonly listSignedInForUser: (
      userId: UserId,
      now: number,
    ) => Effect.Effect<ReadonlyArray<Device>, SqlError.SqlError>;
    /**
     * Devices with no live session (none unrevoked and unexpired at `now`) that weren't seen
     * since `idleSince`, longest unseen first.
     */
    readonly listSignedOut: (
      now: number,
      idleSince: number,
      limit: number,
    ) => Effect.Effect<ReadonlyArray<Device>, SqlError.SqlError>;
    /**
     * Deletes the device if it still has no live session at `now` (see `listSignedOut`).
     * Answers whether it did.
     */
    readonly deleteIfNoLiveSession: (
      id: DeviceId,
      now: number,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    /** Whether the device has any sessions left; none means it signed out for good. */
    readonly hasSessions: (id: DeviceId) => Effect.Effect<boolean, SqlError.SqlError>;
    /**
     * Deletes the device if it has no sessions left, i.e. it signed out. Answers whether it did.
     */
    readonly deleteIfSignedOut: (id: DeviceId) => Effect.Effect<boolean, SqlError.SqlError>;
    /** Records that the device just used the API. */
    readonly touch: (id: DeviceId) => Effect.Effect<void, SqlError.SqlError>;
    readonly setPushToken: (
      id: DeviceId,
      token: string | null,
    ) => Effect.Effect<void, SqlError.SqlError>;
    readonly delete: (id: DeviceId) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/Devices") {
  static readonly layer = Layer.effect(
    Devices,
    Effect.gen(function* () {
      const db = yield* CoreDb;
      /** A live session on the device: not revoked, not expired at `now`. */
      const liveSession = (deviceId: SQLWrapper | DeviceId, now: number) =>
        db
          .select({ id: sessions.id })
          .from(sessions)
          .where(
            and(
              eq(sessions.deviceId, deviceId),
              isNull(sessions.revokedAt),
              gt(sessions.expiresAt, now),
            ),
          );
      /** Any session on the device, live or not. */
      const anySession = (deviceId: DeviceId) =>
        db.select({ id: sessions.id }).from(sessions).where(eq(sessions.deviceId, deviceId));
      const decodeAll = (rows: ReadonlyArray<unknown>) => Effect.forEach(rows, decodeDevice);

      return Devices.of({
        create: Effect.fn("Devices.create")(function* (input) {
          const now = yield* Clock.currentTimeMillis;
          // Validate before writing, so invalid input never reaches the database.
          const device = yield* Schema.decodeUnknownEffect(Device)({
            ...input,
            id: yield* newDeviceId,
            pushToken: null,
            createdAt: now,
            lastSeenAt: now,
          });
          yield* query(
            db.insert(devices).values({
              id: device.id,
              userId: device.userId,
              app: device.app,
              platform: device.platform,
              name: device.name,
              pushToken: null,
              createdAt: device.createdAt,
              lastSeenAt: device.lastSeenAt,
            }),
          );
          return device;
        }),
        findById: Effect.fn("Devices.findById")(function* (id) {
          const rows = yield* query(db.select().from(devices).where(eq(devices.id, id)));
          return yield* first(decodeDevice)(rows);
        }),
        listForUser: Effect.fn("Devices.listForUser")(function* (userId) {
          return yield* decodeAll(
            yield* query(
              db
                .select()
                .from(devices)
                .where(eq(devices.userId, userId))
                .orderBy(devices.createdAt, devices.id),
            ),
          );
        }),
        listSignedInForUser: Effect.fn("Devices.listSignedInForUser")(function* (userId, now) {
          return yield* decodeAll(
            yield* query(
              db
                .select()
                .from(devices)
                .where(and(eq(devices.userId, userId), exists(liveSession(devices.id, now))))
                .orderBy(devices.createdAt, devices.id),
            ),
          );
        }),
        listSignedOut: Effect.fn("Devices.listSignedOut")(function* (now, idleSince, limit) {
          return yield* decodeAll(
            yield* query(
              db
                .select()
                .from(devices)
                .where(
                  and(lt(devices.lastSeenAt, idleSince), notExists(liveSession(devices.id, now))),
                )
                .orderBy(devices.lastSeenAt, devices.id)
                .limit(limit),
            ),
          );
        }),
        deleteIfNoLiveSession: Effect.fn("Devices.deleteIfNoLiveSession")(function* (id, now) {
          const rows = yield* query(
            db
              .delete(devices)
              .where(and(eq(devices.id, id), notExists(liveSession(id, now))))
              .returning({ id: devices.id }),
          );
          return rows.length > 0;
        }),
        hasSessions: Effect.fn("Devices.hasSessions")(function* (id) {
          const rows = yield* query(anySession(id).limit(1));
          return rows.length > 0;
        }),
        deleteIfSignedOut: Effect.fn("Devices.deleteIfSignedOut")(function* (id) {
          const rows = yield* query(
            db
              .delete(devices)
              .where(
                and(
                  eq(devices.id, id),
                  notExists(
                    db.select({ id: sessions.id }).from(sessions).where(eq(sessions.deviceId, id)),
                  ),
                ),
              )
              .returning({ id: devices.id }),
          );
          return rows.length > 0;
        }),
        touch: Effect.fn("Devices.touch")(function* (id) {
          const now = yield* Clock.currentTimeMillis;
          yield* query(db.update(devices).set({ lastSeenAt: now }).where(eq(devices.id, id)));
        }),
        setPushToken: Effect.fn("Devices.setPushToken")(function* (id, token) {
          yield* query(db.update(devices).set({ pushToken: token }).where(eq(devices.id, id)));
        }),
        delete: Effect.fn("Devices.delete")(function* (id) {
          yield* query(db.delete(devices).where(eq(devices.id, id)));
        }),
      });
    }),
  );
}
