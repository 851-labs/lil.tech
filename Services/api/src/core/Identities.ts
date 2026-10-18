import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { and, eq, exists, ne } from "drizzle-orm";
import { alias } from "drizzle-orm/sqlite-core";
import type { SqlError } from "effect/sql";
import { CoreDb, first, query } from "./CoreDb.ts";
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

const decodeIdentity = Schema.decodeUnknownEffect(Identity);

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
     * Deletes the user's identity `id`, unless it's their last, in one statement, so two
     * concurrent unlinks can't remove both of a user's last two.
     */
    readonly deleteUnlessLast: (
      userId: UserId,
      id: IdentityId,
    ) => Effect.Effect<"deleted" | "last" | "notFound", SqlError.SqlError>;
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
              emailVerified: identity.emailVerified,
              createdAt: identity.createdAt,
            }),
          );
          return identity;
        }),
        find: Effect.fn("Identities.find")(function* (provider, subject) {
          const rows = yield* query(
            db
              .select(columns)
              .from(identities)
              .where(and(eq(identities.provider, provider), eq(identities.subject, subject))),
          );
          return yield* first(decodeIdentity)(rows);
        }),
        listForUser: Effect.fn("Identities.listForUser")(function* (userId) {
          const rows = yield* query(
            db
              .select(columns)
              .from(identities)
              .where(eq(identities.userId, userId))
              .orderBy(identities.createdAt, identities.id),
          );
          return yield* Effect.forEach(rows, (row) => decodeIdentity(row).pipe(Effect.orDie));
        }),
        delete: Effect.fn("Identities.delete")(function* (id) {
          yield* query(db.delete(identities).where(eq(identities.id, id)));
        }),
        deleteUnlessLast: Effect.fn("Identities.deleteUnlessLast")(function* (userId, id) {
          const other = alias(identities, "other");
          const deleted = yield* query(
            db
              .delete(identities)
              .where(
                and(
                  eq(identities.id, id),
                  eq(identities.userId, userId),
                  exists(
                    db
                      .select({ id: other.id })
                      .from(other)
                      .where(and(eq(other.userId, userId), ne(other.id, id))),
                  ),
                ),
              )
              .returning({ id: identities.id }),
          );
          if (deleted.length > 0) return "deleted";
          const remaining = yield* query(
            db
              .select({ id: identities.id })
              .from(identities)
              .where(and(eq(identities.id, id), eq(identities.userId, userId))),
          );
          return remaining.length > 0 ? "last" : "notFound";
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
