import { Context, Effect, Layer } from "effect";
import { lt } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, query } from "./CoreDb.ts";
import { identityTokenUses } from "./Schema.ts";

/** Provider ID tokens already exchanged for a session (`identity_token_uses`). */
export class IdentityTokenUses extends Context.Service<
  IdentityTokenUses,
  {
    /**
     * Records a token's use and reports whether it was the first, so each token signs in once.
     * Forgets tokens that have expired.
     */
    readonly claim: (input: {
      readonly tokenHash: string;
      readonly expiresAt: number;
      readonly now: number;
    }) => Effect.Effect<boolean, SqlError.SqlError>;
  }
>()("lil/api/core/IdentityTokenUses") {
  static readonly layer = Layer.effect(
    IdentityTokenUses,
    Effect.gen(function* () {
      const db = yield* CoreDb;
      return IdentityTokenUses.of({
        claim: Effect.fn("IdentityTokenUses.claim")(function* ({ tokenHash, expiresAt, now }) {
          yield* query(db.delete(identityTokenUses).where(lt(identityTokenUses.expiresAt, now)));
          const rows = yield* query(
            db
              .insert(identityTokenUses)
              .values({ tokenHash, expiresAt })
              .onConflictDoNothing()
              .returning({ tokenHash: identityTokenUses.tokenHash }),
          );
          return rows.length === 1;
        }),
      });
    }),
  );
}
