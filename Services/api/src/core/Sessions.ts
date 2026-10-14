import { Context, Effect, Layer, Option, Schema } from "effect";
import { SqlClient, type SqlError } from "effect/sql";
import { DeviceId, SessionId, UserId } from "./Ids.ts";

/** One refresh token. Rotating a token revokes its row and adds a new one in the same family. */
export class Session extends Schema.Class<Session>("lil/api/core/Session")({
  id: SessionId,
  userId: UserId,
  deviceId: DeviceId,
  familyId: Schema.NonEmptyString,
  createdAt: Schema.Number,
  expiresAt: Schema.Number,
  revokedAt: Schema.NullOr(Schema.Number),
}) {}

const decodeSession = (row: unknown) => Schema.decodeUnknownEffect(Session)(row).pipe(Effect.orDie);

export class Sessions extends Context.Service<
  Sessions,
  {
    readonly create: (
      session: Session,
      refreshTokenHash: string,
    ) => Effect.Effect<void, SqlError.SqlError>;
    readonly findByRefreshTokenHash: (
      hash: string,
    ) => Effect.Effect<Option.Option<Session>, SqlError.SqlError>;
    /**
     * Revokes the session if it's still active, and reports whether it was. Only one of two
     * concurrent calls for the same session gets `true`, which is what makes rotation safe without
     * transactions (D1 has none over HTTP).
     */
    readonly revokeIfActive: (
      id: SessionId,
      now: number,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    readonly revokeFamily: (
      familyId: string,
      now: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** Revokes every session in the family of the given session. */
    readonly revokeFamilyOf: (id: SessionId, now: number) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/Sessions") {
  static readonly layer = Layer.effect(
    Sessions,
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;
      return Sessions.of({
        create: Effect.fn("Sessions.create")(function* (session, refreshTokenHash) {
          yield* sql`INSERT INTO sessions
            (id, user_id, device_id, family_id, refresh_token_hash, created_at, expires_at, revoked_at)
            VALUES (${session.id}, ${session.userId}, ${session.deviceId}, ${session.familyId},
              ${refreshTokenHash}, ${session.createdAt}, ${session.expiresAt}, ${session.revokedAt})`;
        }),
        findByRefreshTokenHash: Effect.fn("Sessions.findByRefreshTokenHash")(function* (hash) {
          const rows = yield* sql`SELECT id, user_id AS "userId", device_id AS "deviceId",
            family_id AS "familyId", created_at AS "createdAt", expires_at AS "expiresAt",
            revoked_at AS "revokedAt" FROM sessions WHERE refresh_token_hash = ${hash}`;
          const row = rows[0];
          if (row === undefined) return Option.none();
          return Option.some(yield* decodeSession(row));
        }),
        revokeIfActive: Effect.fn("Sessions.revokeIfActive")(function* (id, now) {
          const rows = yield* sql`UPDATE sessions SET revoked_at = ${now}
            WHERE id = ${id} AND revoked_at IS NULL RETURNING id`;
          return rows.length === 1;
        }),
        revokeFamily: Effect.fn("Sessions.revokeFamily")(function* (familyId, now) {
          yield* sql`UPDATE sessions SET revoked_at = ${now}
            WHERE family_id = ${familyId} AND revoked_at IS NULL`;
        }),
        revokeFamilyOf: Effect.fn("Sessions.revokeFamilyOf")(function* (id, now) {
          yield* sql`UPDATE sessions SET revoked_at = ${now}
            WHERE family_id = (SELECT family_id FROM sessions WHERE id = ${id}) AND revoked_at IS NULL`;
        }),
      });
    }),
  );
}
