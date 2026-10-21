import { Context, Effect, Layer, Option, Schema } from "effect";
import { and, eq, gt, inArray, isNotNull, isNull, lt, lte, notExists, or } from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, first, query } from "./CoreDb.ts";
import { AgentAuthorizationId, AgentGrantId, UserId } from "./Ids.ts";
import { agentAuthorizations, agentGrants, agentTokens, oauthClients } from "./Schema.ts";

// Storage for the agents' authorization server (`docs/decisions/accounts.md`, Agents): approved
// authorizations, grants and their tokens. `AgentTokens` (`src/oauth/AgentTokens.ts`) is the logic
// over it. D1 has no transactions over HTTP, so every step that must happen once is a single
// guarded statement.

/** An approved authorization, as the token endpoint reads it by its code. */
export class AgentAuthorization extends Schema.Class<AgentAuthorization>(
  "lil/api/core/AgentAuthorization",
)({
  id: AgentAuthorizationId,
  clientId: Schema.String,
  redirectUri: Schema.String,
  codeChallenge: Schema.String,
  resource: Schema.String,
  userId: UserId,
  grantedScopes: Schema.Array(Schema.String),
  codeExpiresAt: Schema.Number,
  usedAt: Schema.NullOr(Schema.Number),
  grantId: Schema.NullOr(AgentGrantId),
  /** The client as it's stored: what the consent page showed. */
  clientName: Schema.NullOr(Schema.String),
  clientKind: Schema.Literals(["cimd", "dcr"]),
}) {}

/** A connected agent: one user's grant to one client, for one app's MCP server (`resource`). */
export class AgentGrant extends Schema.Class<AgentGrant>("lil/api/core/AgentGrant")({
  id: AgentGrantId,
  userId: UserId,
  clientId: Schema.String,
  clientName: Schema.NullOr(Schema.String),
  clientDomain: Schema.NullOr(Schema.String),
  redirectHost: Schema.String,
  scopes: Schema.Array(Schema.String),
  resource: Schema.String,
  createdAt: Schema.Number,
  lastUsedAt: Schema.Number,
}) {}

export const AgentTokenKind = Schema.Literals(["access", "refresh"]);
export type AgentTokenKind = typeof AgentTokenKind.Type;

/** A stored token (only its hash), and its grant. */
export class StoredAgentToken extends Schema.Class<StoredAgentToken>(
  "lil/api/core/StoredAgentToken",
)({
  tokenHash: Schema.String,
  kind: AgentTokenKind,
  replaces: Schema.NullOr(Schema.String),
  refreshTokenHash: Schema.NullOr(Schema.String),
  expiresAt: Schema.Number,
  usedAt: Schema.NullOr(Schema.Number),
  grant: AgentGrant,
}) {}

/** A token to store. */
export interface NewAgentToken {
  readonly tokenHash: string;
  readonly kind: AgentTokenKind;
  readonly replaces: string | null;
  readonly refreshTokenHash: string | null;
  readonly expiresAt: number;
}

/** How long a grant without tokens is kept, so the cleanup can't catch one between its writes. */
const emptyGrantAge = 24 * 60 * 60 * 1000;

const decodeAuthorization = Schema.decodeUnknownEffect(AgentAuthorization);
const decodeToken = Schema.decodeUnknownEffect(StoredAgentToken);

export class AgentGrants extends Context.Service<
  AgentGrants,
  {
    /** The approved authorization whose code hashes to `codeHash`, with its client. */
    readonly findAuthorizationByCode: (
      codeHash: string,
    ) => Effect.Effect<Option.Option<AgentAuthorization>, SqlError.SqlError>;
    /**
     * Marks an authorization's code redeemed, for the grant `grantId`, if it wasn't already. Only
     * one of two concurrent redemptions gets `true`.
     */
    readonly redeemCode: (
      id: AgentAuthorizationId,
      grantId: AgentGrantId,
      now: number,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    /** Clears the grant an authorization's code made, before that grant is deleted. */
    readonly forgetGrant: (id: AgentAuthorizationId) => Effect.Effect<void, SqlError.SqlError>;
    readonly createGrant: (grant: AgentGrant) => Effect.Effect<void, SqlError.SqlError>;
    /** Deletes a grant, and with it its tokens. */
    readonly deleteGrant: (id: AgentGrantId) => Effect.Effect<void, SqlError.SqlError>;
    /** Records that a grant was used, unless it was after `before`. */
    readonly touchGrant: (
      id: AgentGrantId,
      now: number,
      before: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** Stores tokens. A pair's refresh token comes before the access token that names it. */
    readonly createTokens: (
      grantId: AgentGrantId,
      tokens: ReadonlyArray<NewAgentToken>,
    ) => Effect.Effect<void, SqlError.SqlError>;
    readonly findToken: (
      tokenHash: string,
    ) => Effect.Effect<Option.Option<StoredAgentToken>, SqlError.SqlError>;
    /** Records the first use of the tokens with these hashes. Later uses keep the first time. */
    readonly markUsed: (
      tokenHashes: ReadonlyArray<string>,
      now: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /**
     * Whether a refresh token that replaced `tokenHash` (only those that expire before
     * `expiringBefore`, if given: issued earlier) has had its pair used: if so, `tokenHash` is
     * dead, and presenting it is reuse.
     */
    readonly successorUsed: (
      tokenHash: string,
      expiringBefore?: number,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    /**
     * Deletes the unused pairs that replaced `tokenHash` and were issued before `expiresAt` (an
     * earlier try of a refresh whose response was lost), with their access tokens.
     */
    readonly deleteUnusedSuccessors: (
      tokenHash: string,
      expiresAt: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
    readonly deleteToken: (tokenHash: string) => Effect.Effect<void, SqlError.SqlError>;
    /**
     * Deletes expired tokens and authorizations, and grants left without a refresh token, which
     * have ended. Returns how many of each.
     */
    readonly deleteExpired: (now: number) => Effect.Effect<
      {
        readonly tokens: number;
        readonly authorizations: number;
        readonly grants: number;
      },
      SqlError.SqlError
    >;
  }
>()("lil/api/core/AgentGrants") {
  static readonly layer = Layer.effect(
    AgentGrants,
    Effect.gen(function* () {
      const db = yield* CoreDb;
      return AgentGrants.of({
        findAuthorizationByCode: Effect.fn("AgentGrants.findAuthorizationByCode")(
          function* (codeHash) {
            const rows = yield* query(
              db
                .select({
                  id: agentAuthorizations.id,
                  clientId: agentAuthorizations.clientId,
                  redirectUri: agentAuthorizations.redirectUri,
                  codeChallenge: agentAuthorizations.codeChallenge,
                  resource: agentAuthorizations.resource,
                  userId: agentAuthorizations.userId,
                  grantedScopes: agentAuthorizations.grantedScopes,
                  codeExpiresAt: agentAuthorizations.codeExpiresAt,
                  usedAt: agentAuthorizations.usedAt,
                  grantId: agentAuthorizations.grantId,
                  clientName: oauthClients.name,
                  clientKind: oauthClients.kind,
                })
                .from(agentAuthorizations)
                .innerJoin(oauthClients, eq(oauthClients.clientId, agentAuthorizations.clientId))
                .where(
                  and(
                    eq(agentAuthorizations.codeHash, codeHash),
                    isNotNull(agentAuthorizations.userId),
                  ),
                ),
            );
            return yield* first(decodeAuthorization)(rows);
          },
        ),
        redeemCode: Effect.fn("AgentGrants.redeemCode")(function* (id, grantId, now) {
          const rows = yield* query(
            db
              .update(agentAuthorizations)
              .set({ usedAt: now, grantId })
              .where(and(eq(agentAuthorizations.id, id), isNull(agentAuthorizations.usedAt)))
              .returning({ id: agentAuthorizations.id }),
          );
          return rows.length === 1;
        }),
        forgetGrant: Effect.fn("AgentGrants.forgetGrant")(function* (id) {
          yield* query(
            db
              .update(agentAuthorizations)
              .set({ grantId: null })
              .where(eq(agentAuthorizations.id, id)),
          );
        }),
        createGrant: Effect.fn("AgentGrants.createGrant")(function* (grant) {
          yield* query(
            db.insert(agentGrants).values({
              id: grant.id,
              userId: grant.userId,
              clientId: grant.clientId,
              clientName: grant.clientName,
              clientDomain: grant.clientDomain,
              redirectHost: grant.redirectHost,
              scopes: grant.scopes,
              resource: grant.resource,
              createdAt: grant.createdAt,
              lastUsedAt: grant.lastUsedAt,
            }),
          );
        }),
        deleteGrant: Effect.fn("AgentGrants.deleteGrant")(function* (id) {
          yield* query(db.delete(agentGrants).where(eq(agentGrants.id, id)));
        }),
        touchGrant: Effect.fn("AgentGrants.touchGrant")(function* (id, now, before) {
          yield* query(
            db
              .update(agentGrants)
              .set({ lastUsedAt: now })
              .where(and(eq(agentGrants.id, id), lte(agentGrants.lastUsedAt, before))),
          );
        }),
        createTokens: Effect.fn("AgentGrants.createTokens")(function* (grantId, tokens) {
          if (tokens.length === 0) return;
          yield* query(
            db.insert(agentTokens).values(tokens.map((token) => ({ ...token, grantId }))),
          );
        }),
        findToken: Effect.fn("AgentGrants.findToken")(function* (tokenHash) {
          const rows = yield* query(
            db
              .select({
                tokenHash: agentTokens.tokenHash,
                kind: agentTokens.kind,
                replaces: agentTokens.replaces,
                refreshTokenHash: agentTokens.refreshTokenHash,
                expiresAt: agentTokens.expiresAt,
                usedAt: agentTokens.usedAt,
                grant: {
                  id: agentGrants.id,
                  userId: agentGrants.userId,
                  clientId: agentGrants.clientId,
                  clientName: agentGrants.clientName,
                  clientDomain: agentGrants.clientDomain,
                  redirectHost: agentGrants.redirectHost,
                  scopes: agentGrants.scopes,
                  resource: agentGrants.resource,
                  createdAt: agentGrants.createdAt,
                  lastUsedAt: agentGrants.lastUsedAt,
                },
              })
              .from(agentTokens)
              .innerJoin(agentGrants, eq(agentGrants.id, agentTokens.grantId))
              .where(eq(agentTokens.tokenHash, tokenHash)),
          );
          return yield* first(decodeToken)(rows);
        }),
        markUsed: Effect.fn("AgentGrants.markUsed")(function* (tokenHashes, now) {
          if (tokenHashes.length === 0) return;
          yield* query(
            db
              .update(agentTokens)
              .set({ usedAt: now })
              .where(and(inArray(agentTokens.tokenHash, tokenHashes), isNull(agentTokens.usedAt))),
          );
        }),
        successorUsed: Effect.fn("AgentGrants.successorUsed")(
          function* (tokenHash, expiringBefore) {
            const rows = yield* query(
              db
                .select({ tokenHash: agentTokens.tokenHash })
                .from(agentTokens)
                .where(
                  and(
                    eq(agentTokens.replaces, tokenHash),
                    isNotNull(agentTokens.usedAt),
                    expiringBefore === undefined
                      ? undefined
                      : lt(agentTokens.expiresAt, expiringBefore),
                  ),
                )
                .limit(1),
            );
            return rows.length > 0;
          },
        ),
        deleteUnusedSuccessors: Effect.fn("AgentGrants.deleteUnusedSuccessors")(
          function* (tokenHash, expiresAt) {
            yield* query(
              db
                .delete(agentTokens)
                .where(
                  and(
                    eq(agentTokens.replaces, tokenHash),
                    isNull(agentTokens.usedAt),
                    lt(agentTokens.expiresAt, expiresAt),
                  ),
                ),
            );
          },
        ),
        deleteToken: Effect.fn("AgentGrants.deleteToken")(function* (tokenHash) {
          yield* query(db.delete(agentTokens).where(eq(agentTokens.tokenHash, tokenHash)));
        }),
        deleteExpired: Effect.fn("AgentGrants.deleteExpired")(function* (now) {
          const tokens = yield* query(
            db
              .delete(agentTokens)
              .where(lte(agentTokens.expiresAt, now))
              .returning({ tokenHash: agentTokens.tokenHash }),
          );
          const authorizations = yield* query(
            db
              .delete(agentAuthorizations)
              .where(
                and(
                  lte(agentAuthorizations.expiresAt, now),
                  or(
                    isNull(agentAuthorizations.codeExpiresAt),
                    lte(agentAuthorizations.codeExpiresAt, now),
                  ),
                ),
              )
              .returning({ id: agentAuthorizations.id }),
          );
          const grants = yield* query(
            db
              .delete(agentGrants)
              .where(
                and(
                  lt(agentGrants.createdAt, now - emptyGrantAge),
                  notExists(
                    db
                      .select({ tokenHash: agentTokens.tokenHash })
                      .from(agentTokens)
                      .where(
                        and(
                          eq(agentTokens.grantId, agentGrants.id),
                          eq(agentTokens.kind, "refresh"),
                          gt(agentTokens.expiresAt, now),
                        ),
                      ),
                  ),
                ),
              )
              .returning({ id: agentGrants.id }),
          );
          return {
            tokens: tokens.length,
            authorizations: authorizations.length,
            grants: grants.length,
          };
        }),
      });
    }),
  );
}
