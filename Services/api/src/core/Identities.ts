import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { and, eq } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, query } from "./CoreDb.ts";
import { IdentityId, newIdentityId, UserId } from "./Ids.ts";
import { identities } from "./Schema.ts";

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
      const db = yield* CoreDb;
      const columns = {
        id: identities.id,
        userId: identities.userId,
        provider: identities.provider,
        subject: identities.subject,
        email: identities.email,
        emailVerified: identities.emailVerified,
        createdAt: identities.createdAt,
      };

      return Identities.of({
        create: Effect.fn("Identities.create")(function* (input) {
          // Validate before writing, so invalid input never reaches the database.
          const identity = yield* Schema.decodeUnknownEffect(Identity)({
            ...input,
            id: yield* newIdentityId,
            createdAt: yield* Clock.currentTimeMillis,
          });
          yield* query(
            db.insert(identities).values({
              id: identity.id,
              userId: identity.userId,
              provider: identity.provider,
              subject: identity.subject,
              email: identity.email,
              emailVerified: identity.emailVerified ? 1 : 0,
              createdAt: identity.createdAt,
            }),
          );
          return identity;
        }),
        find: Effect.fn("Identities.find")(function* (provider, subject) {
          const [row] = yield* query(
            db
              .select(columns)
              .from(identities)
              .where(and(eq(identities.provider, provider), eq(identities.subject, subject))),
          );
          if (row === undefined) return Option.none();
          return Option.some(yield* decodeIdentity(row));
        }),
        listForUser: Effect.fn("Identities.listForUser")(function* (userId) {
          const rows = yield* query(
            db
              .select(columns)
              .from(identities)
              .where(eq(identities.userId, userId))
              .orderBy(identities.createdAt, identities.id),
          );
          return yield* Effect.forEach(rows, decodeIdentity);
        }),
        delete: Effect.fn("Identities.delete")(function* (id) {
          yield* query(db.delete(identities).where(eq(identities.id, id)));
        }),
        saveAppleToken: Effect.fn("Identities.saveAppleToken")(
          function* (subject, refreshToken, clientId) {
            yield* query(
              db
                .update(identities)
                .set({ appleRefreshToken: refreshToken, appleClientId: clientId })
                .where(and(eq(identities.provider, "apple"), eq(identities.subject, subject))),
            );
          },
        ),
      });
    }),
  );
}
