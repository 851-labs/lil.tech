import { Context, Effect, Layer, Option, Schema } from "effect";
import {
  and,
  desc,
  eq,
  exists,
  gt,
  inArray,
  isNotNull,
  isNull,
  lt,
  lte,
  notExists,
  or,
} from "drizzle-orm";
import type { SqlError } from "effect/sql";
import { CoreDb, first, query } from "./CoreDb.ts";
import { AgentAuthorizationId, AgentGrantId, UserId } from "./Ids.ts";
import { agentAuthorizations, agentGrants, agentTokens, oauthClients, users } from "./Schema.ts";

// Storage for the agents' authorization server (`docs/decisions/accounts.md`, Agents):
// authorization requests (`/oauth/authorize`), grants and their tokens. `AgentTokens` (`src/oauth/AgentTokens.ts`) is the logic
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

/**
 * An authorization request on its way through the authorization page (`/oauth/authorize`): asked
 * for, signed in to (`userId`), then allowed (`decided`, once it has a code).
 */
export class PendingAuthorization extends Schema.Class<PendingAuthorization>(
  "lil/api/core/PendingAuthorization",
)({
  id: AgentAuthorizationId,
  clientId: Schema.String,
  redirectUri: Schema.String,
  state: Schema.NullOr(Schema.String),
  scopes: Schema.Array(Schema.String),
  resource: Schema.String,
  browserHash: Schema.String,
  expiresAt: Schema.Number,
  /** Set while the user is signing in with Apple or Google, until they have. */
  signInProvider: Schema.NullOr(Schema.Literals(["apple", "google"])),
  signInStateHash: Schema.NullOr(Schema.String),
  signInNonce: Schema.NullOr(Schema.String),
  userId: Schema.NullOr(UserId),
  /** The signed-in user's name, if they have one. */
  userName: Schema.NullOr(Schema.String),
  /** Set once it's allowed. */
  codeHash: Schema.NullOr(Schema.String),
  codeExpiresAt: Schema.NullOr(Schema.Number),
  /** Set once its code is redeemed. */
  usedAt: Schema.NullOr(Schema.Number),
  clientName: Schema.NullOr(Schema.String),
  clientKind: Schema.Literals(["cimd", "dcr"]),
}) {
  /** Whether it was allowed (Cancel deletes it). */
  get decided() {
    return this.codeHash !== null;
  }
}

/** A new authorization request, before anyone has signed in. */
export interface NewAgentAuthorization {
  readonly id: AgentAuthorizationId;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly state: string | null;
  readonly codeChallenge: string;
  readonly scopes: ReadonlyArray<string>;
  readonly resource: string;
  readonly browserHash: string;
  readonly createdAt: number;
  readonly expiresAt: number;
}

/** Signing in to an authorization request with Apple or Google, as it's started. */
export interface ProviderSignInStart {
  readonly provider: "apple" | "google";
  /** The SHA-256 hex of the `state` sent to the provider. */
  readonly stateHash: string;
  /** The nonce whose SHA-256 the provider's ID token must carry. */
  readonly nonce: string;
}

/** What allowing an authorization records: the scopes granted and the code's hash. */
export interface AgentAuthorizationApproval {
  readonly id: AgentAuthorizationId;
  readonly userId: UserId;
  readonly grantedScopes: ReadonlyArray<string>;
  readonly codeHash: string;
  readonly codeExpiresAt: number;
  readonly now: number;
}

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
  /** Any request, recorded at most every 5 minutes; `createdAt` until then. */
  lastUsedAt: Schema.Number,
  /** The first tool call, recorded exactly. `null` until it reads anything. */
  firstUsedAt: Schema.NullOr(Schema.Number),
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
const decodePending = Schema.decodeUnknownEffect(PendingAuthorization);
const decodeToken = Schema.decodeUnknownEffect(StoredAgentToken);
const decodeGrants = Schema.decodeUnknownEffect(Schema.Array(AgentGrant));

export class AgentGrants extends Context.Service<
  AgentGrants,
  {
    /** Stores a new authorization request, bound to its browser by `browserHash`. */
    readonly createAuthorization: (
      authorization: NewAgentAuthorization,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** An authorization request, with its client and who signed in, while it hasn't expired. */
    readonly findPendingAuthorization: (
      id: AgentAuthorizationId,
      now: number,
    ) => Effect.Effect<Option.Option<PendingAuthorization>, SqlError.SqlError>;
    /**
     * Records who signed in to an authorization request, unless someone already has, it was
     * decided, or it expired. Whether it did.
     */
    readonly signInAuthorization: (
      id: AgentAuthorizationId,
      userId: UserId,
      now: number,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    /**
     * Starts signing in to an authorization request with Apple or Google, replacing any sign-in
     * started before, unless someone has signed in, it was decided, or it expired. Whether it did.
     */
    readonly startProviderSignIn: (
      id: AgentAuthorizationId,
      start: ProviderSignInStart,
      now: number,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    /**
     * Records who signed in with the provider sign-in whose state hashes to `stateHash`, and
     * forgets that sign-in, so its callback works once. Unless someone already signed in, it was
     * decided, or it expired. Whether it did.
     */
    readonly finishProviderSignIn: (
      id: AgentAuthorizationId,
      stateHash: string,
      userId: UserId,
      now: number,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    /**
     * Allows an authorization request that `userId` signed in to and nobody decided yet, giving it
     * a code. Whether it did: of two at once, only one does.
     */
    readonly approveAuthorization: (
      approval: AgentAuthorizationApproval,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
    /** Deletes an authorization request that wasn't allowed (Cancel). Whether it did. */
    readonly deleteUndecidedAuthorization: (
      id: AgentAuthorizationId,
    ) => Effect.Effect<boolean, SqlError.SqlError>;
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
    /**
     * The user's grants that still work (with a refresh token that hasn't expired), most recently
     * connected first. Ended ones wait for the daily cleanup, unlisted.
     */
    readonly listForUser: (
      userId: UserId,
      now: number,
    ) => Effect.Effect<ReadonlyArray<AgentGrant>, SqlError.SqlError | Schema.SchemaError>;
    /**
     * Deletes one of the user's grants, and with it its tokens. Another user's, or one that's
     * gone, is left alone.
     */
    readonly deleteForUser: (
      userId: UserId,
      id: AgentGrantId,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** The resources of the user's grants and authorization requests, each once. */
    readonly resourcesForUser: (
      userId: UserId,
    ) => Effect.Effect<ReadonlyArray<string>, SqlError.SqlError>;
    /**
     * Deletes the user's grants for these MCP servers (`resource`), with their tokens. Their
     * authorization requests go first, so a code allowed just before can't make a grant after:
     * redeeming it finds its authorization gone and deletes the grant it made.
     */
    readonly deleteForResources: (
      userId: UserId,
      resources: ReadonlyArray<string>,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** Records that a grant was used, unless it was after `before`. */
    readonly touchGrant: (
      id: AgentGrantId,
      now: number,
      before: number,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /** Records a grant's first tool call, as its first and last use, unless one was recorded. */
    readonly recordFirstUse: (
      id: AgentGrantId,
      now: number,
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
        createAuthorization: Effect.fn("AgentGrants.createAuthorization")(
          function* (authorization) {
            yield* query(db.insert(agentAuthorizations).values(authorization));
          },
        ),
        findPendingAuthorization: Effect.fn("AgentGrants.findPendingAuthorization")(
          function* (id, now) {
            const rows = yield* query(
              db
                .select({
                  id: agentAuthorizations.id,
                  clientId: agentAuthorizations.clientId,
                  redirectUri: agentAuthorizations.redirectUri,
                  state: agentAuthorizations.state,
                  scopes: agentAuthorizations.scopes,
                  resource: agentAuthorizations.resource,
                  browserHash: agentAuthorizations.browserHash,
                  expiresAt: agentAuthorizations.expiresAt,
                  signInProvider: agentAuthorizations.signInProvider,
                  signInStateHash: agentAuthorizations.signInStateHash,
                  signInNonce: agentAuthorizations.signInNonce,
                  userId: agentAuthorizations.userId,
                  userName: users.displayName,
                  codeHash: agentAuthorizations.codeHash,
                  codeExpiresAt: agentAuthorizations.codeExpiresAt,
                  usedAt: agentAuthorizations.usedAt,
                  clientName: oauthClients.name,
                  clientKind: oauthClients.kind,
                })
                .from(agentAuthorizations)
                .innerJoin(oauthClients, eq(oauthClients.clientId, agentAuthorizations.clientId))
                .leftJoin(users, eq(users.id, agentAuthorizations.userId))
                .where(and(eq(agentAuthorizations.id, id), gt(agentAuthorizations.expiresAt, now))),
            );
            return yield* first(decodePending)(rows);
          },
        ),
        signInAuthorization: Effect.fn("AgentGrants.signInAuthorization")(
          function* (id, userId, now) {
            const rows = yield* query(
              db
                .update(agentAuthorizations)
                .set({ userId })
                .where(
                  and(
                    eq(agentAuthorizations.id, id),
                    isNull(agentAuthorizations.userId),
                    isNull(agentAuthorizations.codeHash),
                    gt(agentAuthorizations.expiresAt, now),
                  ),
                )
                .returning({ id: agentAuthorizations.id }),
            );
            return rows.length === 1;
          },
        ),
        startProviderSignIn: Effect.fn("AgentGrants.startProviderSignIn")(
          function* (id, start, now) {
            const rows = yield* query(
              db
                .update(agentAuthorizations)
                .set({
                  signInProvider: start.provider,
                  signInStateHash: start.stateHash,
                  signInNonce: start.nonce,
                })
                .where(
                  and(
                    eq(agentAuthorizations.id, id),
                    isNull(agentAuthorizations.userId),
                    isNull(agentAuthorizations.codeHash),
                    gt(agentAuthorizations.expiresAt, now),
                  ),
                )
                .returning({ id: agentAuthorizations.id }),
            );
            return rows.length === 1;
          },
        ),
        finishProviderSignIn: Effect.fn("AgentGrants.finishProviderSignIn")(
          function* (id, stateHash, userId, now) {
            const rows = yield* query(
              db
                .update(agentAuthorizations)
                .set({ userId, signInProvider: null, signInStateHash: null, signInNonce: null })
                .where(
                  and(
                    eq(agentAuthorizations.id, id),
                    eq(agentAuthorizations.signInStateHash, stateHash),
                    isNull(agentAuthorizations.userId),
                    isNull(agentAuthorizations.codeHash),
                    gt(agentAuthorizations.expiresAt, now),
                  ),
                )
                .returning({ id: agentAuthorizations.id }),
            );
            return rows.length === 1;
          },
        ),
        approveAuthorization: Effect.fn("AgentGrants.approveAuthorization")(function* (approval) {
          const rows = yield* query(
            db
              .update(agentAuthorizations)
              .set({
                grantedScopes: approval.grantedScopes,
                codeHash: approval.codeHash,
                codeExpiresAt: approval.codeExpiresAt,
              })
              .where(
                and(
                  eq(agentAuthorizations.id, approval.id),
                  eq(agentAuthorizations.userId, approval.userId),
                  isNull(agentAuthorizations.codeHash),
                  gt(agentAuthorizations.expiresAt, approval.now),
                ),
              )
              .returning({ id: agentAuthorizations.id }),
          );
          return rows.length === 1;
        }),
        deleteUndecidedAuthorization: Effect.fn("AgentGrants.deleteUndecidedAuthorization")(
          function* (id) {
            const rows = yield* query(
              db
                .delete(agentAuthorizations)
                .where(and(eq(agentAuthorizations.id, id), isNull(agentAuthorizations.codeHash)))
                .returning({ id: agentAuthorizations.id }),
            );
            return rows.length === 1;
          },
        ),
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
              firstUsedAt: grant.firstUsedAt,
            }),
          );
        }),
        deleteGrant: Effect.fn("AgentGrants.deleteGrant")(function* (id) {
          yield* query(db.delete(agentGrants).where(eq(agentGrants.id, id)));
        }),
        listForUser: Effect.fn("AgentGrants.listForUser")(function* (userId, now) {
          const rows = yield* query(
            db
              .select()
              .from(agentGrants)
              .where(
                and(
                  eq(agentGrants.userId, userId),
                  exists(
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
              .orderBy(desc(agentGrants.createdAt), desc(agentGrants.id)),
          );
          return yield* decodeGrants(rows);
        }),
        deleteForUser: Effect.fn("AgentGrants.deleteForUser")(function* (userId, id) {
          yield* query(
            db
              .delete(agentGrants)
              .where(and(eq(agentGrants.id, id), eq(agentGrants.userId, userId))),
          );
        }),
        resourcesForUser: Effect.fn("AgentGrants.resourcesForUser")(function* (userId) {
          const [granted, asked] = yield* Effect.all(
            [
              query(
                db
                  .selectDistinct({ resource: agentGrants.resource })
                  .from(agentGrants)
                  .where(eq(agentGrants.userId, userId)),
              ),
              query(
                db
                  .selectDistinct({ resource: agentAuthorizations.resource })
                  .from(agentAuthorizations)
                  .where(eq(agentAuthorizations.userId, userId)),
              ),
            ],
            { concurrency: "unbounded" },
          );
          return [...new Set([...granted, ...asked].map((row) => row.resource))];
        }),
        deleteForResources: Effect.fn("AgentGrants.deleteForResources")(
          function* (userId, resources) {
            if (resources.length === 0) return;
            yield* query(
              db
                .delete(agentAuthorizations)
                .where(
                  and(
                    eq(agentAuthorizations.userId, userId),
                    inArray(agentAuthorizations.resource, resources),
                  ),
                ),
            );
            yield* query(
              db
                .delete(agentGrants)
                .where(
                  and(eq(agentGrants.userId, userId), inArray(agentGrants.resource, resources)),
                ),
            );
          },
        ),
        touchGrant: Effect.fn("AgentGrants.touchGrant")(function* (id, now, before) {
          yield* query(
            db
              .update(agentGrants)
              .set({ lastUsedAt: now })
              .where(and(eq(agentGrants.id, id), lte(agentGrants.lastUsedAt, before))),
          );
        }),
        recordFirstUse: Effect.fn("AgentGrants.recordFirstUse")(function* (id, now) {
          yield* query(
            db
              .update(agentGrants)
              .set({ firstUsedAt: now, lastUsedAt: now })
              .where(and(eq(agentGrants.id, id), isNull(agentGrants.firstUsedAt))),
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
                  firstUsedAt: agentGrants.firstUsedAt,
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
