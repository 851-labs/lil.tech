import { Context, Effect, Layer } from "effect";
import { SqlClient, type SqlError } from "effect/sql";

/** Provider ID tokens already exchanged for a session (core migration 0002). */
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
      const sql = yield* SqlClient.SqlClient;
      return IdentityTokenUses.of({
        claim: Effect.fn("IdentityTokenUses.claim")(function* ({ tokenHash, expiresAt, now }) {
          yield* sql`DELETE FROM identity_token_uses WHERE expires_at < ${now}`;
          const rows = yield* sql`INSERT INTO identity_token_uses (token_hash, expires_at)
            VALUES (${tokenHash}, ${expiresAt}) ON CONFLICT (token_hash) DO NOTHING
            RETURNING token_hash`;
          return rows.length === 1;
        }),
      });
    }),
  );
}
