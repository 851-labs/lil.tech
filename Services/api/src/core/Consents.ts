import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { and, desc, eq, isNull } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, query } from "./CoreDb.ts";
import type { UserId } from "./Ids.ts";
import { consents } from "./Schema.ts";

/**
 * What a user can consent to. `health`: processing their Health data (GDPR Article 9).
 * `agents:health`: letting agents they connect read their lil health data through its MCP server,
 * asked each time one connects (851-2849). Each later app gets its own agents consent
 * (`agents:mail`), so turning one app's agents off leaves the others.
 */
export const ConsentType = Schema.Literals(["health", "agents:health"]);
export type ConsentType = typeof ConsentType.Type;

/**
 * The privacy policy version (its effective date) that consent to processing Health data must
 * be for. Bumping it, for a change in how Health data is used, asks everyone to consent again.
 */
export const healthConsentPolicyVersion = "2026-10-15";

/**
 * The privacy policy version that consent to an app's agents is recorded against, separate from
 * Health consent's, so asking for it never asks anyone to consent to Health again: the policy
 * that describes agents connected to the account (851-2855).
 */
export const agentsConsentPolicyVersions = {
  "agents:health": "2026-10-21",
} as const satisfies Record<Extract<ConsentType, `agents:${string}`>, string>;

/** A consent in force. */
export interface GivenConsent {
  readonly policyVersion: string;
  /** Unix milliseconds. */
  readonly grantedAt: number;
}

/** Whether `given` allows uploading Health data: it's for the current policy version. */
export const isCurrentHealthConsent = (given: Option.Option<GivenConsent>) =>
  Option.isSome(given) && given.value.policyVersion === healthConsentPolicyVersion;

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
      const db = yield* CoreDb;
      const current = Effect.fn("Consents.current")(function* (userId: UserId, type: ConsentType) {
        const rows = yield* query(
          db
            .select({ policyVersion: consents.policyVersion, grantedAt: consents.grantedAt })
            .from(consents)
            .where(
              and(
                eq(consents.userId, userId),
                eq(consents.type, type),
                isNull(consents.withdrawnAt),
              ),
            )
            .orderBy(desc(consents.grantedAt), desc(consents.id))
            .limit(1),
        );
        return Option.fromNullishOr(rows[0]);
      });
      return Consents.of({
        current,
        grant: Effect.fn("Consents.grant")(function* (userId, type, policyVersion) {
          const grantedAt = yield* Clock.currentTimeMillis;
          // The `consents_active` index keeps it to one active consent, so requests that race (an
          // app retrying) record it once.
          yield* query(
            db
              .insert(consents)
              .values({ userId, type, policyVersion, grantedAt })
              .onConflictDoNothing(),
          );
          const given = yield* current(userId, type);
          return Option.getOrElse(given, () => ({ policyVersion, grantedAt }));
        }),
        withdraw: Effect.fn("Consents.withdraw")(function* (userId, type) {
          const now = yield* Clock.currentTimeMillis;
          yield* query(
            db
              .update(consents)
              .set({ withdrawnAt: now })
              .where(
                and(
                  eq(consents.userId, userId),
                  eq(consents.type, type),
                  isNull(consents.withdrawnAt),
                ),
              ),
          );
        }),
      });
    }),
  );
}
