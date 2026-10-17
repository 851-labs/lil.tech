import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { SqlClient, type SqlError } from "effect/sql";
import { IdentityId, newIdentityId, UserId } from "./Ids.ts";

export const IdentityProvider = Schema.Literals(["apple", "google"]);
export type IdentityProvider = typeof IdentityProvider.Type;

/** A way to sign in, e.g. a user's Sign in with Apple account. */
export class Identity extends Schema.Class<Identity>("lil/api/core/Identity")({
  id: IdentityId,
  userId: UserId,
  provider: IdentityProvider,
  /** The provider's stable ID for the account (the `sub` claim). */
  subject: Schema.NonEmptyString,
  email: Schema.NullOr(Schema.String),
  emailVerified: Schema.Boolean,
  createdAt: Schema.Number,
}) {}

const decodeIdentity = (row: Record<string, unknown>) =>
  Schema.decodeUnknownEffect(Identity)({ ...row, emailVerified: row["emailVerified"] === 1 }).pipe(
    Effect.orDie,
  );

export class Identities extends Context.Service<
  Identities,
  {
    readonly create: (input: {
      readonly userId: UserId;
      readonly provider: IdentityProvider;
      readonly subject: string;
      readonly email: string | null;
      readonly emailVerified: boolean;
    }) => Effect.Effect<Identity, SqlError.SqlError | Schema.SchemaError>;
    readonly find: (
      provider: IdentityProvider,
      subject: string,
    ) => Effect.Effect<Option.Option<Identity>, SqlError.SqlError>;
    readonly listForUser: (
      userId: UserId,
    ) => Effect.Effect<ReadonlyArray<Identity>, SqlError.SqlError>;
    readonly delete: (id: IdentityId) => Effect.Effect<void, SqlError.SqlError>;
    /**
     * Keeps Apple's refresh token (encrypted, see `AppleTokens`) for the Apple account `subject`,
     * and the client ID it was issued to, so deleting the account can revoke it.
     */
    readonly saveAppleToken: (
      subject: string,
      refreshToken: string,
      clientId: string,
    ) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/Identities") {
  static readonly layer = Layer.effect(
    Identities,
    Effect.gen(function* () {
      const sql = yield* SqlClient.SqlClient;
      const select = sql`SELECT id, user_id AS "userId", provider, subject, email,
        email_verified AS "emailVerified", created_at AS "createdAt" FROM identities`;

      return Identities.of({
        create: Effect.fn("Identities.create")(function* (input) {
          // Validate before writing, so invalid input never reaches the database.
          const identity = yield* Schema.decodeUnknownEffect(Identity)({
            ...input,
            id: yield* newIdentityId,
            createdAt: yield* Clock.currentTimeMillis,
          });
          yield* sql`INSERT INTO identities
            (id, user_id, provider, subject, email, email_verified, created_at)
            VALUES (${identity.id}, ${identity.userId}, ${identity.provider}, ${identity.subject},
              ${identity.email}, ${identity.emailVerified ? 1 : 0}, ${identity.createdAt})`;
          return identity;
        }),
        find: Effect.fn("Identities.find")(function* (provider, subject) {
          const rows = yield* sql`${select} WHERE provider = ${provider} AND subject = ${subject}`;
          const row = rows[0];
          if (row === undefined) return Option.none();
          return Option.some(yield* decodeIdentity(row));
        }),
        listForUser: Effect.fn("Identities.listForUser")(function* (userId) {
          const rows = yield* sql`${select} WHERE user_id = ${userId} ORDER BY created_at, id`;
          return yield* Effect.forEach(rows, decodeIdentity);
        }),
        delete: Effect.fn("Identities.delete")(function* (id) {
          yield* sql`DELETE FROM identities WHERE id = ${id}`;
        }),
        saveAppleToken: Effect.fn("Identities.saveAppleToken")(
          function* (subject, refreshToken, clientId) {
            yield* sql`UPDATE identities
              SET apple_refresh_token = ${refreshToken}, apple_client_id = ${clientId}
              WHERE provider = 'apple' AND subject = ${subject}`;
          },
        ),
      });
    }),
  );
}
