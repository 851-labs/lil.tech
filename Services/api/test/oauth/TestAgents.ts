import { createHash, randomBytes } from "node:crypto";
import { Clock, Effect, Layer } from "effect";
import { AgentTokens, authorizationCodeLifetime } from "../../src/oauth/AgentTokens.ts";
import { CoreDb } from "../../src/core/CoreDb.ts";
import { newAgentAuthorizationId, newOAuthClientId, type UserId } from "../../src/core/Ids.ts";
import { agentAuthorizations, oauthClients } from "../../src/core/Schema.ts";
import { Users } from "../../src/core/Users.ts";
import { RateLimits } from "../../src/RateLimits.ts";
import { TestCore } from "../core/TestCoreDatabase.ts";

// Agents' clients and approved authorizations, stored directly, for tests of the tokens. The
// authorization page's own tests (`AuthorizationPage.test.ts`) go through the page.

/** lil health's MCP server in prod: its tokens' audience. */
export const healthResource = "https://mcp.lil.tech/health";

/** Claude Code's Client ID Metadata Document, which its `client_id` is. */
export const claudeCode = "https://claude.ai/oauth/claude-code-client-metadata";

/** `AgentTokens` over a fresh test database, without rate limits. */
export const TestAgents = AgentTokens.layer.pipe(
  Layer.provideMerge(TestCore),
  Layer.provideMerge(Layer.succeed(RateLimits, RateLimits.unlimited)),
);

/** A PKCE verifier and its S256 challenge. */
export const pkce = () => {
  const verifier = randomBytes(32).toString("base64url");
  return { verifier, challenge: createHash("sha256").update(verifier).digest("base64url") };
};

const sha256Hex = (value: string) => createHash("sha256").update(value).digest("hex");

/** Stores Claude Code's client, as resolving its metadata document would. */
export const storeClaudeCode = Effect.gen(function* () {
  const db = yield* CoreDb;
  const now = yield* Clock.currentTimeMillis;
  yield* db
    .insert(oauthClients)
    .values({
      id: yield* newOAuthClientId,
      clientId: claudeCode,
      kind: "cimd",
      name: "Claude Code",
      clientUri: "https://claude.ai",
      redirectUris: ["http://localhost/callback", "http://127.0.0.1/callback"],
      applicationType: "native",
      expiresAt: now + 5 * 60 * 1000,
      createdAt: now,
      lastUsedAt: now,
    })
    .onConflictDoNothing();
  return claudeCode;
}).pipe(Effect.orDie);

export interface Approval {
  readonly userId: UserId;
  readonly clientId: string;
  readonly code: string;
  readonly verifier: string;
  readonly redirectUri: string;
  readonly resource: string;
}

/**
 * An authorization the user allowed, as the consent page leaves it: a code for `clientId`, with an
 * S256 challenge (or `challenge`, to store another), for `resource`. Makes a user unless given one.
 */
export const approve = (
  options: {
    readonly clientId?: string;
    readonly userId?: UserId;
    readonly redirectUri?: string;
    readonly resource?: string;
    readonly challenge?: (verifier: string) => string;
  } = {},
) =>
  Effect.gen(function* () {
    const db = yield* CoreDb;
    const now = yield* Clock.currentTimeMillis;
    const clientId = options.clientId ?? (yield* storeClaudeCode);
    const userId =
      options.userId ??
      (yield* (yield* Users).create({ displayName: "Ada" }).pipe(Effect.orDie)).id;
    const redirectUri = options.redirectUri ?? "http://localhost:53712/callback";
    const resource = options.resource ?? healthResource;
    const { verifier, challenge } = pkce();
    const code = randomBytes(32).toString("base64url");
    yield* db.insert(agentAuthorizations).values({
      id: yield* newAgentAuthorizationId,
      clientId,
      redirectUri,
      state: "state-1",
      codeChallenge: options.challenge?.(verifier) ?? challenge,
      scopes: ["health:read"],
      resource,
      browserHash: sha256Hex("browser"),
      createdAt: now,
      expiresAt: now + 10 * 60 * 1000,
      userId,
      grantedScopes: ["health:read"],
      codeHash: sha256Hex(code),
      codeExpiresAt: now + authorizationCodeLifetime,
    });
    return { userId, clientId, code, verifier, redirectUri, resource } satisfies Approval;
  }).pipe(Effect.orDie);
