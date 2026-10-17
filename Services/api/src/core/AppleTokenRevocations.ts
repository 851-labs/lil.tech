import { Context, Effect, Layer, Schema } from "effect";
import { SqlClient, type SqlError } from "effect/sql";
import { IdentityId, type UserId } from "./Ids.ts";

/** An Apple refresh token (encrypted) waiting to be revoked, from a deleted account. */
export class AppleTokenRevocation extends Schema.Class<AppleTokenRevocation>(
  "lil/api/core/AppleTokenRevocation",
)({
  /** The identity the token belonged to. */
  id: IdentityId,
  refreshToken: Schema.String,
  clientId: Schema.String,
  /** How many times revoking it failed. */
  attempts: Schema.Number,
}) {}

const decodeRevocation = Schema.decodeUnknownEffect(AppleTokenRevocation);

/** Apple tokens to revoke (`AppleTokens.ts`), kept past their account's deletion until they are. */
export class AppleTokenRevocations extends Context.Service<
  AppleTokenRevocations,
  {
    /**
     * Copies the user's stored Apple tokens here, before the account (and its identities) is
     * deleted. Doing it again copies nothing new. Returns the identities that had a token.
     */
    readonly addForUser: (
      userId: UserId,
      now: number,
    ) => Effect.Effect<ReadonlyArray<IdentityId>, SqlError.SqlError>;
    /** The given revocations that are still waiting. */
    readonly find: (
      ids: ReadonlyArray<IdentityId>,
    ) => Effect.Effect<ReadonlyArray<AppleTokenRevocation>, SqlError.SqlError>;
    /** Up to `limit` revocations whose next attempt is due at `now`, oldest first. */
    readonly listDue: (
      now: number,
      limit: number,
    ) => Effect.Effect<ReadonlyArray<AppleTokenRevocation>, SqlError.SqlError>;
    /** Forgets a revocation: it went through, or it's given up on. */
    readonly remove: (id: IdentityId) => Effect.Effect<void, SqlError.SqlError>;
    /** Records a failed attempt, and when to try next. */
    readonly postpone: (
      id: IdentityId,
      attempts: number,
      nextAttemptAt: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/AppleTokenRevocations") {
  static readonly layer = Layer.effect(
    AppleTokenRevocations,
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;
      const select = sql`SELECT id, refresh_token AS "refreshToken", client_id AS "clientId",
        attempts FROM apple_token_revocations`;
      const decodeAll = (rows: ReadonlyArray<unknown>) =>
        Effect.forEach(rows, (row) => decodeRevocation(row).pipe(Effect.orDie));

      return AppleTokenRevocations.of({
        addForUser: Effect.fn("AppleTokenRevocations.addForUser")(function* (userId, now) {
          // The identity's ID keys it, so a retried deletion doesn't add it twice.
          yield* sql`INSERT OR IGNORE INTO apple_token_revocations
            (id, refresh_token, client_id, attempts, next_attempt_at, created_at)
            SELECT id, apple_refresh_token, apple_client_id, 0, ${now}, ${now} FROM identities
            WHERE user_id = ${userId} AND apple_refresh_token IS NOT NULL
              AND apple_client_id IS NOT NULL`;
          const rows = yield* sql<{ id: IdentityId }>`SELECT id FROM identities
            WHERE user_id = ${userId} AND apple_refresh_token IS NOT NULL
              AND apple_client_id IS NOT NULL`;
          return rows.map((row) => row.id);
        }),
        find: Effect.fn("AppleTokenRevocations.find")(function* (ids) {
          if (ids.length === 0) return [];
          return yield* decodeAll(
            yield* sql`${select} WHERE id IN (SELECT value FROM json_each(${JSON.stringify(ids)}))`,
          );
        }),
        listDue: Effect.fn("AppleTokenRevocations.listDue")(function* (now, limit) {
          return yield* decodeAll(
            yield* sql`${select} WHERE next_attempt_at <= ${now}
              ORDER BY next_attempt_at, id LIMIT ${limit}`,
          );
        }),
        remove: Effect.fn("AppleTokenRevocations.remove")(function* (id) {
          yield* sql`DELETE FROM apple_token_revocations WHERE id = ${id}`;
        }),
        postpone: Effect.fn("AppleTokenRevocations.postpone")(
          function* (id, attempts, nextAttemptAt) {
            yield* sql`UPDATE apple_token_revocations
              SET attempts = ${attempts}, next_attempt_at = ${nextAttemptAt} WHERE id = ${id}`;
          },
        ),
      });
    }),
  );
}
