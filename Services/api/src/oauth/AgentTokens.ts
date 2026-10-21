import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import type { SqlError } from "effect/sql";
import { newOpaqueToken, sha256Base64url, sha256Hex } from "../auth/Tokens.ts";
import {
  type AgentAuthorization,
  AgentGrant,
  AgentGrants,
  type NewAgentToken,
  type StoredAgentToken,
} from "../core/AgentGrants.ts";
import { type AgentGrantId, newAgentGrantId } from "../core/Ids.ts";
import { RateLimits, type TooManyRequests } from "../RateLimits.ts";

// Agents' tokens (`docs/decisions/accounts.md`, Agents): the token endpoint's two grants (an
// authorization code with PKCE, and a rotating refresh token), revocation, and the check each MCP
// server makes on every request. Tokens are opaque and stored only as SHA-256 hashes, so every
// request reads its grant, and revoking one cuts the agent off at once.

/** How long an access token (`lma_…`) works. */
export const agentAccessTokenLifetime = 60 * 60 * 1000;

/** How long a refresh token (`lmr_…`) works, from when it's issued. Each rotation starts anew. */
export const agentRefreshTokenLifetime = 90 * 24 * 60 * 60 * 1000;

/** How long a pending authorization is kept (`/oauth/authorize`, 851-2849). */
export const agentAuthorizationLifetime = 10 * 60 * 1000;

/** How long an authorization code works once the user allowed it. */
export const authorizationCodeLifetime = 60 * 1000;

/**
 * How often, at most, `verify` records that a grant was used, to save writes. Its first tool call
 * is recorded exactly (`recordFirstUse`).
 */
export const grantLastUsedInterval = 5 * 60 * 1000;

const accessTokenPrefix = "lma";
const refreshTokenPrefix = "lmr";

/**
 * Why a token request (`POST /oauth/token`) was refused, as RFC 6749 §5.2 (and RFC 8707's
 * `invalid_target`) names it. Every dead code or token is `invalid_grant`.
 */
export class TokenRequestError extends Schema.TaggedError<TokenRequestError>()(
  "TokenRequestError",
  {
    error: Schema.Literals([
      "invalid_request",
      "invalid_grant",
      "invalid_target",
      "invalid_scope",
      "unsupported_grant_type",
    ]),
    description: Schema.String,
  },
) {}

/**
 * A bearer token an MCP server can't accept: unknown, revoked, not an agent's access token, or for
 * another app's server (`invalid`), or past its hour (`expired`).
 */
export class InvalidAgentToken extends Schema.TaggedError<InvalidAgentToken>()(
  "InvalidAgentToken",
  { reason: Schema.Literals(["invalid", "expired"]) },
) {}

/** A successful token response's contents (RFC 6749 §5.1). */
export interface AgentTokenPair {
  readonly accessToken: string;
  /** Seconds. */
  readonly expiresIn: number;
  readonly refreshToken: string;
  /** The grant's scopes, space-separated. */
  readonly scope: string;
}

export interface CodeExchange {
  readonly code: string;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly codeVerifier: string;
  readonly resource: Option.Option<string>;
}

export interface RefreshRequest {
  readonly refreshToken: string;
  readonly clientId: string;
  readonly resource: Option.Option<string>;
  readonly scope: Option.Option<string>;
}

/** A PKCE code verifier (RFC 7636 §4.1). */
const codeVerifierPattern = /^[A-Za-z0-9._~-]{43,128}$/;

/** Whether `verifier` is the one `challenge` was made from, with S256 (RFC 7636 §4.6). */
const verifierMatches = (verifier: string, challenge: string) =>
  codeVerifierPattern.test(verifier)
    ? Effect.map(sha256Base64url(verifier), (hashed) => hashed === challenge)
    : Effect.succeed(false);

/** The host a redirect URI goes to, as the consent page names it: its scheme, if it has no host. */
export const redirectHost = (redirectUri: string) => {
  const url = new URL(redirectUri);
  return url.hostname === "" ? url.protocol.slice(0, -1) : url.hostname;
};

const invalidGrant = (description: string) =>
  new TokenRequestError({ error: "invalid_grant", description });

export class AgentTokens extends Context.Service<
  AgentTokens,
  {
    /**
     * Redeems an approved authorization's code for a new grant and its first pair (the
     * `authorization_code` grant). A code works once: redeeming it again deletes the grant it
     * made.
     */
    readonly exchangeCode: (
      request: CodeExchange,
    ) => Effect.Effect<AgentTokenPair, TokenRequestError | TooManyRequests | SqlError.SqlError>;
    /**
     * Rotates a refresh token (the `refresh_token` grant). The token presented keeps working until
     * the pair it's exchanged for is first used, and each retry before then replaces the unused
     * pair. Presenting it after that is reuse, which deletes the grant.
     */
    readonly refresh: (
      request: RefreshRequest,
    ) => Effect.Effect<AgentTokenPair, TokenRequestError | TooManyRequests | SqlError.SqlError>;
    /**
     * Revokes a token (RFC 7009): a refresh token ends its grant, an access token only itself.
     * Unknown tokens, and another client's, are ignored.
     */
    readonly revoke: (
      token: string,
      clientId: Option.Option<string>,
    ) => Effect.Effect<void, SqlError.SqlError>;
    /**
     * The grant an access token is for, if it's valid for `resource`, the MCP server asking. A
     * token for another app's server is invalid, so no app reads with another's token. The first
     * use of a pair ends the grace of the refresh token it replaced.
     */
    readonly verify: (
      token: string,
      resource: string,
    ) => Effect.Effect<AgentGrant, InvalidAgentToken | SqlError.SqlError>;
    /**
     * Records a verified grant's first tool call, its first read, as its first and last use, so
     * the apps can tell it has read something even within `grantLastUsedInterval` of connecting.
     * Only the first is written; a failure is logged, and doesn't fail the call.
     */
    readonly recordFirstUse: (grant: AgentGrant) => Effect.Effect<void>;
  }
>()("lil/api/oauth/AgentTokens") {
  static readonly layer = Layer.effect(
    AgentTokens,
    Effect.gen(function* () {
      const grants = yield* AgentGrants;
      const limits = yield* RateLimits;

      /** Issues and stores a new pair for the grant, replacing the refresh token `replaces`. */
      const issue = Effect.fnUntraced(function* (
        grantId: AgentGrantId,
        scopes: ReadonlyArray<string>,
        replaces: string | null,
      ) {
        const now = yield* Clock.currentTimeMillis;
        const accessToken = yield* newOpaqueToken(accessTokenPrefix);
        const refreshToken = yield* newOpaqueToken(refreshTokenPrefix);
        const refresh: NewAgentToken = {
          tokenHash: yield* sha256Hex(refreshToken),
          kind: "refresh",
          replaces,
          refreshTokenHash: null,
          expiresAt: now + agentRefreshTokenLifetime,
        };
        const access: NewAgentToken = {
          tokenHash: yield* sha256Hex(accessToken),
          kind: "access",
          replaces: null,
          refreshTokenHash: refresh.tokenHash,
          expiresAt: now + agentAccessTokenLifetime,
        };
        yield* grants.createTokens(grantId, [refresh, access]);
        const pair: AgentTokenPair = {
          accessToken,
          expiresIn: agentAccessTokenLifetime / 1000,
          refreshToken,
          scope: scopes.join(" "),
        };
        return { pair, refresh };
      });

      /** Finds a stored token of `kind`, if `token` looks like one. */
      const find = (token: string, kind: StoredAgentToken["kind"]) => {
        const prefix = kind === "access" ? accessTokenPrefix : refreshTokenPrefix;
        if (!token.startsWith(`${prefix}_`)) return Effect.succeed(Option.none());
        return sha256Hex(token).pipe(
          Effect.flatMap(grants.findToken),
          Effect.map(Option.filter((stored) => stored.kind === kind)),
        );
      };

      /**
       * Ends the grant a redeemed code made. The authorization forgets it first, so a redemption
       * still making it sees that and deletes it itself, if this ran before the grant existed.
       */
      const endGrantOf = (authorization: AgentAuthorization) =>
        authorization.grantId === null
          ? Effect.void
          : grants
              .forgetGrant(authorization.id)
              .pipe(Effect.andThen(grants.deleteGrant(authorization.grantId)));

      /** Reuse: only a stolen copy is presented after its successor was used, so the grant ends. */
      const reused = (grantId: AgentGrantId) =>
        grants
          .deleteGrant(grantId)
          .pipe(Effect.andThen(Effect.fail(invalidGrant("The refresh token was already used"))));

      return AgentTokens.of({
        exchangeCode: Effect.fn("AgentTokens.exchangeCode")(function* (request) {
          const now = yield* Clock.currentTimeMillis;
          const codeHash = yield* sha256Hex(request.code);
          const found = yield* grants.findAuthorizationByCode(codeHash);
          if (Option.isNone(found)) {
            return yield* invalidGrant("The authorization code is invalid");
          }
          const authorization = found.value;
          // Per authorization, the grant it makes: not per client, whose ID is public and shared
          // by every user of a hosted agent, so anyone could use up its budget.
          yield* limits.check("agentToken", `authorization:${authorization.id}`);
          // Only a request that could have redeemed the code counts as redeeming it again: one
          // with the client, redirect URI and verifier. A used code alone, seen in a log or
          // history, can't end the grant.
          if (authorization.clientId !== request.clientId) {
            return yield* invalidGrant("The authorization code was issued to another client");
          }
          if (authorization.redirectUri !== request.redirectUri) {
            return yield* invalidGrant("The redirect URI isn't the authorization's");
          }
          if (
            Option.isSome(request.resource) &&
            request.resource.value !== authorization.resource
          ) {
            return yield* new TokenRequestError({
              error: "invalid_target",
              description: `The authorization is for ${authorization.resource}`,
            });
          }
          if (!(yield* verifierMatches(request.codeVerifier, authorization.codeChallenge))) {
            return yield* invalidGrant("The code verifier doesn't match the code challenge");
          }
          if (authorization.usedAt !== null) {
            // A code redeemed twice may have been stolen, so the grant it made ends (RFC 6749
            // §4.1.2).
            yield* endGrantOf(authorization);
            return yield* invalidGrant("The authorization code was already used");
          }
          if (authorization.codeExpiresAt <= now) {
            return yield* invalidGrant("The authorization code has expired");
          }

          const grantId = yield* newAgentGrantId;
          // Claims the code first, so of two concurrent redemptions only one makes a grant.
          if (!(yield* grants.redeemCode(authorization.id, grantId, now))) {
            const again = yield* grants.findAuthorizationByCode(codeHash);
            if (Option.isSome(again)) yield* endGrantOf(again.value);
            return yield* invalidGrant("The authorization code was already used");
          }
          yield* grants.createGrant(
            new AgentGrant({
              id: grantId,
              userId: authorization.userId,
              clientId: authorization.clientId,
              clientName: authorization.clientName,
              clientDomain:
                authorization.clientKind === "cimd"
                  ? new URL(authorization.clientId).hostname
                  : null,
              redirectHost: redirectHost(authorization.redirectUri),
              scopes: authorization.grantedScopes,
              resource: authorization.resource,
              createdAt: now,
              lastUsedAt: now,
              firstUsedAt: null,
            }),
          );
          const { pair } = yield* issue(grantId, authorization.grantedScopes, null);
          // A second redemption while this one ran may have tried to end the grant before it
          // existed. It cleared the authorization's grant first, so that shows here.
          const after = yield* grants.findAuthorizationByCode(codeHash);
          if (Option.getOrUndefined(after)?.grantId !== grantId) {
            yield* grants.deleteGrant(grantId);
            return yield* invalidGrant("The authorization code was already used");
          }
          return pair;
        }),

        refresh: Effect.fn("AgentTokens.refresh")(function* (request) {
          const now = yield* Clock.currentTimeMillis;
          const found = yield* find(request.refreshToken, "refresh");
          if (Option.isNone(found)) return yield* invalidGrant("The refresh token is invalid");
          const token = found.value;
          const grant = token.grant;
          yield* limits.check("agentToken", `grant:${grant.id}`);
          if (grant.clientId !== request.clientId) {
            return yield* invalidGrant("The refresh token was issued to another client");
          }
          if (Option.isSome(request.resource) && request.resource.value !== grant.resource) {
            return yield* new TokenRequestError({
              error: "invalid_target",
              description: `The grant is for ${grant.resource}`,
            });
          }
          if (Option.isSome(request.scope)) {
            const extra = request.scope.value
              .split(" ")
              .filter((scope) => scope !== "" && !grant.scopes.includes(scope));
            if (extra.length > 0) {
              return yield* new TokenRequestError({
                error: "invalid_scope",
                description: `The grant doesn't include ${extra.join(" ")}`,
              });
            }
          }
          if (token.expiresAt <= now) return yield* invalidGrant("The refresh token has expired");
          if (yield* grants.successorUsed(token.tokenHash)) return yield* reused(grant.id);

          // No transactions over HTTP, so the order keeps this safe, like `Auth.refresh`: this
          // token's use ends its predecessor's grace, then the new pair is stored, then reuse is
          // checked again, and only then are earlier unused pairs dropped. The second check only
          // counts pairs issued before this one: one of those used meanwhile means another party
          // holds this token. A later pair is a retry of this refresh, which may use its pair at
          // once.
          yield* grants.markUsed([token.tokenHash], now);
          const { pair, refresh } = yield* issue(grant.id, grant.scopes, token.tokenHash);
          if (yield* grants.successorUsed(token.tokenHash, refresh.expiresAt)) {
            return yield* reused(grant.id);
          }
          // Housekeeping: an earlier try's pair left behind would only work until it's replaced.
          yield* grants
            .deleteUnusedSuccessors(token.tokenHash, refresh.expiresAt)
            .pipe(Effect.ignore({ log: true }));
          return pair;
        }),

        revoke: Effect.fn("AgentTokens.revoke")(function* (token, clientId) {
          const refresh = yield* find(token, "refresh");
          const stored = Option.isSome(refresh) ? refresh : yield* find(token, "access");
          if (Option.isNone(stored)) return;
          const { grant } = stored.value;
          if (Option.isSome(clientId) && clientId.value !== grant.clientId) return;
          if (stored.value.kind === "refresh") yield* grants.deleteGrant(grant.id);
          else yield* grants.deleteToken(stored.value.tokenHash);
        }),

        verify: Effect.fn("AgentTokens.verify")(function* (token, resource) {
          const now = yield* Clock.currentTimeMillis;
          const found = yield* find(token, "access");
          if (Option.isNone(found)) return yield* new InvalidAgentToken({ reason: "invalid" });
          const stored = found.value;
          // The audience check: a token only works at its own app's MCP server.
          if (stored.grant.resource !== resource) {
            return yield* new InvalidAgentToken({ reason: "invalid" });
          }
          if (stored.expiresAt <= now) return yield* new InvalidAgentToken({ reason: "expired" });
          yield* Effect.all(
            [
              // The pair's first use, which ends the grace of the refresh token it replaced.
              stored.usedAt === null
                ? grants.markUsed(
                    stored.refreshTokenHash === null
                      ? [stored.tokenHash]
                      : [stored.tokenHash, stored.refreshTokenHash],
                    now,
                  )
                : Effect.void,
              stored.grant.lastUsedAt <= now - grantLastUsedInterval
                ? grants
                    .touchGrant(stored.grant.id, now, now - grantLastUsedInterval)
                    .pipe(Effect.ignore({ log: true }))
                : Effect.void,
            ],
            { concurrency: "unbounded", discard: true },
          );
          return stored.grant;
        }),

        recordFirstUse: Effect.fn("AgentTokens.recordFirstUse")(function* (grant) {
          if (grant.firstUsedAt !== null) return;
          yield* grants
            .recordFirstUse(grant.id, yield* Clock.currentTimeMillis)
            .pipe(Effect.ignore({ log: true }));
        }),
      });
    }),
  );
}
