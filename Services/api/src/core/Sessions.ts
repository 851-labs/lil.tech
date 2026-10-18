import { Context, Effect, Layer, Option, Schema } from "effect";
import { and, eq, inArray, isNull, lte } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, first, query } from "./CoreDb.ts";
import { DeviceId, SessionId, UserId } from "./Ids.ts";
import { sessions } from "./Schema.ts";

/** One refresh token. Rotating a token revokes its row and adds a new one in the same family. */
export class Session extends Schema.Class<Session>("lil/api/core/Session")({
  id: SessionId,
  userId: UserId,
  deviceId: DeviceId,
  /** The ID of the family's first session. */
  familyId: SessionId,
  createdAt: Schema.Number,
  expiresAt: Schema.Number,
  revokedAt: Schema.NullOr(Schema.Number),
}) {}

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
      familyId: SessionId,
      now: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** Deletes every session in the family of the given session. */
    readonly deleteFamilyOf: (id: SessionId) => Effect.Effect<void, SqlError.SqlError>;
    /** Deletes the family's expired sessions, which can no longer be used or reused. */
    readonly deleteExpired: (
      familyId: SessionId,
      now: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/Sessions") {
  static readonly layer = Layer.effect(
    Sessions,
    Effect.gen(function* () {
      const db = yield* CoreDb;
      return Sessions.of({
        create: Effect.fn("Sessions.create")(function* (session, refreshTokenHash) {
          yield* query(
            db.insert(sessions).values({
              id: session.id,
              userId: session.userId,
              deviceId: session.deviceId,
              familyId: session.familyId,
              refreshTokenHash,
              createdAt: session.createdAt,
              expiresAt: session.expiresAt,
              revokedAt: session.revokedAt,
            }),
          );
        }),
        findByRefreshTokenHash: Effect.fn("Sessions.findByRefreshTokenHash")(function* (hash) {
          const rows = yield* query(
            db
              .select({
                id: sessions.id,
                userId: sessions.userId,
                deviceId: sessions.deviceId,
                familyId: sessions.familyId,
                createdAt: sessions.createdAt,
                expiresAt: sessions.expiresAt,
                revokedAt: sessions.revokedAt,
              })
              .from(sessions)
              .where(eq(sessions.refreshTokenHash, hash)),
          );
          return yield* first(Schema.decodeUnknownEffect(Session))(rows);
        }),
        revokeIfActive: Effect.fn("Sessions.revokeIfActive")(function* (id, now) {
          const rows = yield* query(
            db
              .update(sessions)
              .set({ revokedAt: now })
              .where(and(eq(sessions.id, id), isNull(sessions.revokedAt)))
              .returning({ id: sessions.id }),
          );
          return rows.length === 1;
        }),
        revokeFamily: Effect.fn("Sessions.revokeFamily")(function* (familyId, now) {
          yield* query(
            db
              .update(sessions)
              .set({ revokedAt: now })
              .where(and(eq(sessions.familyId, familyId), isNull(sessions.revokedAt))),
          );
        }),
        deleteFamilyOf: Effect.fn("Sessions.deleteFamilyOf")(function* (id) {
          yield* query(
            db
              .delete(sessions)
              .where(
                inArray(
                  sessions.familyId,
                  db
                    .select({ familyId: sessions.familyId })
                    .from(sessions)
                    .where(eq(sessions.id, id)),
                ),
              ),
          );
        }),
        deleteExpired: Effect.fn("Sessions.deleteExpired")(function* (familyId, now) {
          yield* query(
            db
              .delete(sessions)
              .where(and(eq(sessions.familyId, familyId), lte(sessions.expiresAt, now))),
          );
        }),
      });
    }),
  );
}
