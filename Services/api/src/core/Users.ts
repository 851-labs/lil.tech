import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { and, eq, isNull, lte, notExists, or } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, query } from "./CoreDb.ts";
import { newUserId, UserId } from "./Ids.ts";
import { identities, users } from "./Schema.ts";

export class User extends Schema.Class<User>("lil/api/core/User")({
  id: UserId,
  displayName: Schema.NullOr(Schema.String),
  createdAt: Schema.Number,
}) {}

const decodeUser = Schema.decodeUnknownEffect(User);

export class Users extends Context.Service<
  Users,
  {
    readonly create: (input: {
      readonly displayName: string | null;
    }) => Effect.Effect<User, SqlError.SqlError | Schema.SchemaError>;
    readonly findById: (id: UserId) => Effect.Effect<Option.Option<User>, SqlError.SqlError>;
    /** Deletes the user and, through foreign keys, their identities, devices, sessions and connections. */
    readonly delete: (id: UserId) => Effect.Effect<void, SqlError.SqlError>;
    /** Sets the display name, unless the user already has one. */
    readonly setDisplayNameIfMissing: (
      id: UserId,
      displayName: string,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** How many users there are. */
    readonly count: Effect.Effect<number, SqlError.SqlError>;
    /**
     * A user with this display name and no sign-in identities: one dev sign-in made
     * (`src/auth/DevSignIn.ts`).
     */
    readonly findSynthetic: (
      displayName: string,
    ) => Effect.Effect<Option.Option<User>, SqlError.SqlError>;
    /**
     * Records the size of the user's store, measured at `measuredAt`, unless a later measurement
     * is already recorded.
     */
    readonly recordStorage: (
      id: UserId,
      bytes: number,
      measuredAt: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/Users") {
  static readonly layer = Layer.effect(
    Users,
    Effect.gen(function* () {
      const db = yield* CoreDb;
      const columns = {
        id: users.id,
        displayName: users.displayName,
        createdAt: users.createdAt,
      };
      const one = (rows: ReadonlyArray<unknown>) =>
        rows[0] === undefined
          ? Effect.succeed(Option.none<User>())
          : decodeUser(rows[0]).pipe(Effect.orDie, Effect.map(Option.some));

      return Users.of({
        create: Effect.fn("Users.create")(function* ({ displayName }) {
          const user = yield* decodeUser({
            id: yield* newUserId,
            displayName,
            createdAt: yield* Clock.currentTimeMillis,
          });
          yield* query(db.insert(users).values(user));
          return user;
        }),
        findById: Effect.fn("Users.findById")(function* (id) {
          return yield* one(yield* query(db.select(columns).from(users).where(eq(users.id, id))));
        }),
        findSynthetic: Effect.fn("Users.findSynthetic")(function* (displayName) {
          const rows = yield* query(
            db
              .select(columns)
              .from(users)
              .where(
                and(
                  eq(users.displayName, displayName),
                  notExists(
                    db
                      .select({ id: identities.id })
                      .from(identities)
                      .where(eq(identities.userId, users.id)),
                  ),
                ),
              )
              .orderBy(users.createdAt)
              .limit(1),
          );
          return yield* one(rows);
        }),
        delete: Effect.fn("Users.delete")(function* (id) {
          yield* query(db.delete(users).where(eq(users.id, id)));
        }),
        setDisplayNameIfMissing: Effect.fn("Users.setDisplayNameIfMissing")(
          function* (id, displayName) {
            yield* query(
              db
                .update(users)
                .set({ displayName })
                .where(and(eq(users.id, id), isNull(users.displayName))),
            );
          },
        ),
        count: query(db.$count(users)).pipe(Effect.withSpan("Users.count")),
        recordStorage: Effect.fn("Users.recordStorage")(function* (id, bytes, measuredAt) {
          // Batches are applied concurrently, so their measurements can arrive out of order.
          yield* query(
            db
              .update(users)
              .set({ storageBytes: bytes, storageMeasuredAt: measuredAt })
              .where(
                and(
                  eq(users.id, id),
                  or(isNull(users.storageMeasuredAt), lte(users.storageMeasuredAt, measuredAt)),
                ),
              ),
          );
        }),
      });
    }),
  );
}
