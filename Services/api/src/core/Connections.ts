import { Clock, Context, Effect, Layer, Schema } from "effect";
import { eq } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, excluded, query } from "./CoreDb.ts";
import { ConnectionId, newConnectionId, UserId } from "./Ids.ts";
import { connections } from "./Schema.ts";

/** Kinds of data source. Apple Health now; mail and calendar accounts later. */
export const ConnectionKind = Schema.Literals([
  "apple_health",
  "google",
  "microsoft",
  "imap",
  "caldav",
]);
export type ConnectionKind = typeof ConnectionKind.Type;

export const ConnectionStatus = Schema.Literals(["active", "needs_reauth", "revoked"]);
export type ConnectionStatus = typeof ConnectionStatus.Type;

/**
 * A data source the user connected. Separate from identities: signing in with Google proves who
 * someone is, and connecting Gmail grants access to their mail, with its own scopes and tokens.
 */
export class Connection extends Schema.Class<Connection>("lil/api/core/Connection")({
  id: ConnectionId,
  userId: UserId,
  kind: ConnectionKind,
  /** The account at the provider, e.g. an email address or an iPhone's device ID. */
  accountRef: Schema.NonEmptyString,
  displayName: Schema.NullOr(Schema.String),
  scopes: Schema.Array(Schema.String),
  /** Encrypted credentials, or `null` when the source needs none (Apple Health). */
  credentials: Schema.NullOr(Schema.String),
  status: ConnectionStatus,
  createdAt: Schema.Number,
  updatedAt: Schema.Number,
}) {}

const decodeConnection = (row: unknown) =>
  Schema.decodeUnknownEffect(Connection)(row).pipe(Effect.orDie);

export class Connections extends Context.Service<
  Connections,
  {
    /**
     * Connects a source, or reconnects it if the user already connected the same account: its
     * scopes and credentials are replaced, and it becomes active again.
     */
    readonly connect: (input: {
      readonly userId: UserId;
      readonly kind: ConnectionKind;
      readonly accountRef: string;
      readonly displayName: string | null;
      readonly scopes: ReadonlyArray<string>;
      readonly credentials: string | null;
    }) => Effect.Effect<Connection, SqlError.SqlError | Schema.SchemaError>;
    readonly listForUser: (
      userId: UserId,
    ) => Effect.Effect<ReadonlyArray<Connection>, SqlError.SqlError>;
    readonly setStatus: (
      id: ConnectionId,
      status: ConnectionStatus,
    ) => Effect.Effect<void, SqlError.SqlError>;
    readonly delete: (id: ConnectionId) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/core/Connections") {
  static readonly layer = Layer.effect(
    Connections,
    Effect.gen(function* () {
      const db = yield* CoreDb;
      return Connections.of({
        connect: Effect.fn("Connections.connect")(function* (input) {
          const now = yield* Clock.currentTimeMillis;
          // Validate before writing, so invalid input never reaches the database.
          const candidate = yield* Schema.decodeUnknownEffect(Connection)({
            ...input,
            id: yield* newConnectionId,
            status: "active",
            createdAt: now,
            updatedAt: now,
          });
          const rows = yield* query(
            db
              .insert(connections)
              .values({
                id: candidate.id,
                userId: candidate.userId,
                kind: candidate.kind,
                accountRef: candidate.accountRef,
                displayName: candidate.displayName,
                scopes: candidate.scopes,
                credentials: candidate.credentials,
                status: "active",
                createdAt: now,
                updatedAt: now,
              })
              .onConflictDoUpdate({
                target: [connections.userId, connections.kind, connections.accountRef],
                set: {
                  displayName: excluded(connections.displayName),
                  scopes: excluded(connections.scopes),
                  credentials: excluded(connections.credentials),
                  status: "active",
                  updatedAt: excluded(connections.updatedAt),
                },
              })
              .returning(),
          );
          const row = rows[0];
          if (row === undefined) {
            return yield* Effect.die(new Error("Upserting a connection returned no row"));
          }
          return yield* decodeConnection(row);
        }),
        listForUser: Effect.fn("Connections.listForUser")(function* (userId) {
          const rows = yield* query(
            db
              .select()
              .from(connections)
              .where(eq(connections.userId, userId))
              .orderBy(connections.createdAt, connections.id),
          );
          return yield* Effect.forEach(rows, decodeConnection);
        }),
        setStatus: Effect.fn("Connections.setStatus")(function* (id, status) {
          const now = yield* Clock.currentTimeMillis;
          yield* query(
            db.update(connections).set({ status, updatedAt: now }).where(eq(connections.id, id)),
          );
        }),
        delete: Effect.fn("Connections.delete")(function* (id) {
          yield* query(db.delete(connections).where(eq(connections.id, id)));
        }),
      });
    }),
  );
}
