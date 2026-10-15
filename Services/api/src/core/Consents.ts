import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { SqlClient, type SqlError } from "effect/sql";
import type { UserId } from "./Ids.ts";

/** What a user can consent to. Health: processing their Health data (GDPR Article 9). */
export const ConsentType = Schema.Literals(["health"]);
export type ConsentType = typeof ConsentType.Type;

/**
 * The privacy policy version (its effective date) that consent to processing Health data must
 * be for. Bumping it, for a change in how Health data is used, asks everyone to consent again.
 */
export const healthConsentPolicyVersion = "2026-10-15";

/** A consent in force. */
export interface GivenConsent {
  readonly policyVersion: string;
  /** Unix milliseconds. */
  readonly grantedAt: number;
}

export class Consents extends Context.Service<
  Consents,
  {
    /** The user's consent of this type that's in force, if any. */
    readonly current: (
      userId: UserId,
      type: ConsentType,
    ) => Effect.Effect<Option.Option<GivenConsent>, SqlError.SqlError>;
    /** Records consent to `policyVersion`. Consenting again to the same version keeps the first. */
    readonly grant: (
      userId: UserId,
      type: ConsentType,
      policyVersion: string,
    ) => Effect.Effect<GivenConsent, SqlError.SqlError>;
    /** Withdraws the user's consent of this type, keeping the record. */
    readonly withdraw: (
      userId: UserId,
      type: ConsentType,
    ) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/Consents") {
  static readonly layer = Layer.effect(
    Consents,
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;
      const current = Effect.fn("Consents.current")(function* (userId: UserId, type: ConsentType) {
        const rows = yield* sql<{ policyVersion: string; grantedAt: number }>`
          SELECT policy_version AS "policyVersion", granted_at AS "grantedAt" FROM consents
          WHERE user_id = ${userId} AND type = ${type} AND withdrawn_at IS NULL
          ORDER BY granted_at DESC, id DESC LIMIT 1`;
        return Option.fromNullishOr(rows[0]);
      });
      return Consents.of({
        current,
        grant: Effect.fn("Consents.grant")(function* (userId, type, policyVersion) {
          const existing = yield* current(userId, type);
          if (Option.isSome(existing) && existing.value.policyVersion === policyVersion) {
            return existing.value;
          }
          const grantedAt = yield* Clock.currentTimeMillis;
          yield* sql`INSERT INTO consents (user_id, type, policy_version, granted_at)
            VALUES (${userId}, ${type}, ${policyVersion}, ${grantedAt})`;
          return { policyVersion, grantedAt };
        }),
        withdraw: Effect.fn("Consents.withdraw")(function* (userId, type) {
          const now = yield* Clock.currentTimeMillis;
          yield* sql`UPDATE consents SET withdrawn_at = ${now}
            WHERE user_id = ${userId} AND type = ${type} AND withdrawn_at IS NULL`;
        }),
      });
    }),
  );
}
