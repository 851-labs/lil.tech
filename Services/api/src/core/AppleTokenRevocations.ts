import { Context, Effect, Layer, Schema } from "effect";
import { eq, lte, sql } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, query } from "./CoreDb.ts";
import { IdentityId } from "./Ids.ts";
import { appleTokenRevocations } from "./Schema.ts";

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

/**
 * Apple tokens to revoke (`AppleTokens.ts`), kept past their identity's deletion until they are.
 * Deleting an identity with a token queues it, from a trigger added by hand to the core
 * baseline migration (`migrations/core/*_baseline/migration.sql`).
 */
export class AppleTokenRevocations extends Context.Service<
  AppleTokenRevocations,
  {
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
      const db = yield* CoreDb;
      const columns = {
        id: appleTokenRevocations.id,
        refreshToken: appleTokenRevocations.refreshToken,
        clientId: appleTokenRevocations.clientId,
        attempts: appleTokenRevocations.attempts,
      };
      const decodeAll = (rows: ReadonlyArray<unknown>) =>
        Effect.forEach(rows, (row) => decodeRevocation(row).pipe(Effect.orDie));

      return AppleTokenRevocations.of({
        find: Effect.fn("AppleTokenRevocations.find")(function* (ids) {
          if (ids.length === 0) return [];
          return yield* decodeAll(
            yield* query(
              db
                .select(columns)
                .from(appleTokenRevocations)
                // One bound parameter however many IDs, below D1's limit of 100 per statement.
                .where(
                  sql`${appleTokenRevocations.id} IN (SELECT value FROM json_each(${JSON.stringify(ids)}))`,
                ),
            ),
          );
        }),
        listDue: Effect.fn("AppleTokenRevocations.listDue")(function* (now, limit) {
          return yield* decodeAll(
            yield* query(
              db
                .select(columns)
                .from(appleTokenRevocations)
                .where(lte(appleTokenRevocations.nextAttemptAt, now))
                .orderBy(appleTokenRevocations.nextAttemptAt, appleTokenRevocations.id)
                .limit(limit),
            ),
          );
        }),
        remove: Effect.fn("AppleTokenRevocations.remove")(function* (id) {
          yield* query(db.delete(appleTokenRevocations).where(eq(appleTokenRevocations.id, id)));
        }),
        postpone: Effect.fn("AppleTokenRevocations.postpone")(
          function* (id, attempts, nextAttemptAt) {
            yield* query(
              db
                .update(appleTokenRevocations)
                .set({ attempts, nextAttemptAt })
                .where(eq(appleTokenRevocations.id, id)),
            );
          },
        ),
      });
    }),
  );
}
