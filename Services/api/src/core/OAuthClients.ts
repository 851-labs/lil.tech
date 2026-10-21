import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import { and, eq, lt, notExists, or, sql } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import {
  type ClientMetadata,
  fetchClientMetadata,
  InvalidClient,
  isClientMetadataUrl,
} from "../oauth/ClientMetadata.ts";
import { CoreDb, excluded, first, query } from "./CoreDb.ts";
import { newOAuthClientId, newRegisteredClientId, OAuthClientId } from "./Ids.ts";
import { agentGrants, oauthClients } from "./Schema.ts";

const OAuthClientRow = Schema.Struct({
  id: OAuthClientId,
  clientId: Schema.String,
  kind: Schema.Literals(["cimd", "dcr"]),
  name: Schema.NullOr(Schema.String),
  clientUri: Schema.NullOr(Schema.String),
  redirectUris: Schema.Array(Schema.String),
  applicationType: Schema.Literals(["web", "native"]),
  expiresAt: Schema.NullOr(Schema.Number),
  createdAt: Schema.Number,
  lastUsedAt: Schema.NullOr(Schema.Number),
});
const decodeRow = Schema.decodeUnknownEffect(OAuthClientRow);

/**
 * An OAuth client of the agents' authorization server (`oauth_clients`). Its `clientId` is the
 * metadata document's URL (`cimd`), or the ID registration issued (`dcr`, `cli_…`). `expiresAt`
 * is when a document's cached copy must be fetched again.
 */
export type OAuthClient = typeof OAuthClientRow.Type;

/** How long a registered client without a grant may go unused before it's deleted. */
export const unusedRegistrationAge = 24 * 60 * 60 * 1000;

/** How long any client without a grant may go unused before it's deleted. */
export const unusedClientAge = 90 * 24 * 60 * 60 * 1000;

/** How often, at most, a client's `last_used_at` is updated, to save writes. */
const lastUsedInterval = 60 * 60 * 1000;

export class OAuthClients extends Context.Service<
  OAuthClients,
  {
    /**
     * The client with `clientId`, for an authorization or token request: a registered one, or the
     * Client ID Metadata Document at that URL, fetched again once its cache expires. Records that
     * it was used.
     */
    readonly resolve: (
      clientId: string,
    ) => Effect.Effect<OAuthClient, InvalidClient | SqlError.SqlError>;
    /** Registers a client (dynamic client registration), issuing it a `cli_…` ID. */
    readonly register: (metadata: ClientMetadata) => Effect.Effect<OAuthClient, SqlError.SqlError>;
    /**
     * Deletes clients without a grant: registered ones once they're a day old and haven't been used
     * for a day (so not one in the middle of an authorization), and any unused for 90 days.
     * Returns how many.
     */
    readonly deleteUnused: Effect.Effect<number, SqlError.SqlError>;
  }
>()("lil/api/core/OAuthClients") {
  static readonly layer = Layer.effect(
    OAuthClients,
    Effect.gen(function* () {
      const db = yield* CoreDb;
      const find = (clientId: string) =>
        query(db.select().from(oauthClients).where(eq(oauthClients.clientId, clientId))).pipe(
          Effect.flatMap(first(decodeRow)),
        );
      const touch = (row: OAuthClient, now: number) =>
        row.lastUsedAt !== null && row.lastUsedAt > now - lastUsedInterval
          ? Effect.succeed(row)
          : query(
              db.update(oauthClients).set({ lastUsedAt: now }).where(eq(oauthClients.id, row.id)),
            ).pipe(Effect.as({ ...row, lastUsedAt: now }));
      return OAuthClients.of({
        resolve: Effect.fn("OAuthClients.resolve")(function* (clientId: string) {
          const now = yield* Clock.currentTimeMillis;
          const cached = yield* find(clientId);
          if (!isClientMetadataUrl(clientId)) {
            if (Option.isNone(cached) || cached.value.kind !== "dcr") {
              return yield* new InvalidClient({
                error: "invalid_client",
                description: "There's no client with this ID",
              });
            }
            return yield* touch(cached.value, now);
          }
          if (Option.isSome(cached) && (cached.value.expiresAt ?? 0) > now) {
            return yield* touch(cached.value, now);
          }
          const { metadata, expiresAt } = yield* fetchClientMetadata(clientId);
          const values = {
            name: metadata.name,
            clientUri: metadata.clientUri,
            redirectUris: metadata.redirectUris,
            applicationType: metadata.applicationType,
            expiresAt,
            lastUsedAt: now,
          };
          const rows = yield* query(
            db
              .insert(oauthClients)
              .values({
                id: yield* newOAuthClientId,
                clientId,
                kind: "cimd",
                createdAt: now,
                ...values,
              })
              .onConflictDoUpdate({
                target: oauthClients.clientId,
                set: {
                  name: excluded(oauthClients.name),
                  clientUri: excluded(oauthClients.clientUri),
                  redirectUris: excluded(oauthClients.redirectUris),
                  applicationType: excluded(oauthClients.applicationType),
                  expiresAt: excluded(oauthClients.expiresAt),
                  lastUsedAt: excluded(oauthClients.lastUsedAt),
                },
                // Never turns a registered client into a document's.
                setWhere: eq(oauthClients.kind, "cimd"),
              })
              .returning(),
          );
          const row = yield* first(decodeRow)(rows);
          if (Option.isNone(row)) {
            return yield* new InvalidClient({
              error: "invalid_client",
              description: "There's no client with this ID",
            });
          }
          return row.value;
        }),
        register: Effect.fn("OAuthClients.register")(function* (metadata: ClientMetadata) {
          const now = yield* Clock.currentTimeMillis;
          const row = {
            id: yield* newOAuthClientId,
            clientId: yield* newRegisteredClientId,
            kind: "dcr" as const,
            name: metadata.name,
            clientUri: metadata.clientUri,
            redirectUris: metadata.redirectUris,
            applicationType: metadata.applicationType,
            expiresAt: null,
            createdAt: now,
            lastUsedAt: null,
          };
          yield* query(db.insert(oauthClients).values(row));
          return row;
        }),
        deleteUnused: Effect.gen(function* () {
          const now = yield* Clock.currentTimeMillis;
          const lastUsed = sql`coalesce(${oauthClients.lastUsedAt}, ${oauthClients.createdAt})`;
          const rows = yield* query(
            db
              .delete(oauthClients)
              .where(
                and(
                  notExists(
                    db
                      .select({ id: agentGrants.id })
                      .from(agentGrants)
                      .where(eq(agentGrants.clientId, oauthClients.clientId)),
                  ),
                  or(
                    and(eq(oauthClients.kind, "dcr"), lt(lastUsed, now - unusedRegistrationAge)),
                    lt(lastUsed, now - unusedClientAge),
                  ),
                ),
              )
              .returning({ id: oauthClients.id }),
          );
          return rows.length;
        }).pipe(Effect.withSpan("OAuthClients.deleteUnused")),
      });
    }),
  );
}
