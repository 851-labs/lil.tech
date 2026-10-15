import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { SqlClient, type SqlError } from "effect/sql";
import { newUserId, UserId } from "./Ids.ts";

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
      const sql = yield* SqlClient.SqlClient;
      const select = sql`SELECT id, display_name AS "displayName", created_at AS "createdAt" FROM users`;

      return Users.of({
        create: Effect.fn("Users.create")(function* ({ displayName }) {
          const user = yield* decodeUser({
            id: yield* newUserId,
            displayName,
            createdAt: yield* Clock.currentTimeMillis,
          });
          yield* sql`INSERT INTO users (id, display_name, created_at)
            VALUES (${user.id}, ${user.displayName}, ${user.createdAt})`;
          return user;
        }),
        findById: Effect.fn("Users.findById")(function* (id) {
          const rows = yield* sql`${select} WHERE id = ${id}`;
          const row = rows[0];
          if (row === undefined) return Option.none();
          return Option.some(yield* decodeUser(row).pipe(Effect.orDie));
        }),
        delete: Effect.fn("Users.delete")(function* (id) {
          yield* sql`DELETE FROM users WHERE id = ${id}`;
        }),
        setDisplayNameIfMissing: Effect.fn("Users.setDisplayNameIfMissing")(
          function* (id, displayName) {
            yield* sql`UPDATE users SET display_name = ${displayName}
            WHERE id = ${id} AND display_name IS NULL`;
          },
        ),
        count: Effect.gen(function* () {
          const rows = yield* sql`SELECT count(*) AS n FROM users`;
          return Number(rows[0]?.["n"] ?? 0);
        }).pipe(Effect.withSpan("Users.count")),
        recordStorage: Effect.fn("Users.recordStorage")(function* (id, bytes, measuredAt) {
          // Batches are applied concurrently, so their measurements can arrive out of order.
          yield* sql`UPDATE users SET storage_bytes = ${bytes}, storage_measured_at = ${measuredAt}
            WHERE id = ${id}
              AND (storage_measured_at IS NULL OR storage_measured_at <= ${measuredAt})`;
        }),
      });
    }),
  );
}
