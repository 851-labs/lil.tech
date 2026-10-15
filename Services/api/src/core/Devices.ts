import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { SqlClient, type SqlError } from "effect/sql";
import { DeviceId, newDeviceId, UserId } from "./Ids.ts";

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
     * `now`. Signing out or in again leaves the old device row, so `listForUser` has those too.
     */
    readonly listSignedInForUser: (
      userId: UserId,
      now: number,
    ) => Effect.Effect<ReadonlyArray<Device>, SqlError.SqlError>;
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
      const sql = yield* SqlClient.SqlClient;
      const select = sql`SELECT id, user_id AS "userId", app, platform, name,
        push_token AS "pushToken", created_at AS "createdAt", last_seen_at AS "lastSeenAt"
        FROM devices`;

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
          yield* sql`INSERT INTO devices
            (id, user_id, app, platform, name, push_token, created_at, last_seen_at)
            VALUES (${device.id}, ${device.userId}, ${device.app}, ${device.platform}, ${device.name},
              NULL, ${device.createdAt}, ${device.lastSeenAt})`;
          return device;
        }),
        findById: Effect.fn("Devices.findById")(function* (id) {
          const rows = yield* sql`${select} WHERE id = ${id}`;
          const row = rows[0];
          if (row === undefined) return Option.none();
          return Option.some(yield* decodeDevice(row));
        }),
        listForUser: Effect.fn("Devices.listForUser")(function* (userId) {
          const rows = yield* sql`${select} WHERE user_id = ${userId} ORDER BY created_at, id`;
          return yield* Effect.forEach(rows, decodeDevice);
        }),
        listSignedInForUser: Effect.fn("Devices.listSignedInForUser")(function* (userId, now) {
          const rows = yield* sql`${select} WHERE user_id = ${userId} AND EXISTS (
              SELECT 1 FROM sessions
              WHERE sessions.device_id = devices.id AND sessions.revoked_at IS NULL
                AND sessions.expires_at > ${now})
            ORDER BY created_at, id`;
          return yield* Effect.forEach(rows, decodeDevice);
        }),
        touch: Effect.fn("Devices.touch")(function* (id) {
          const now = yield* Clock.currentTimeMillis;
          yield* sql`UPDATE devices SET last_seen_at = ${now} WHERE id = ${id}`;
        }),
        setPushToken: Effect.fn("Devices.setPushToken")(function* (id, token) {
          yield* sql`UPDATE devices SET push_token = ${token} WHERE id = ${id}`;
        }),
        delete: Effect.fn("Devices.delete")(function* (id) {
          yield* sql`DELETE FROM devices WHERE id = ${id}`;
        }),
      });
    }),
  );
}
