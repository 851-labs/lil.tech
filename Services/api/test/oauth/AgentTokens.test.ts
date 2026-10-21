import { assert, describe, it } from "@effect/vitest";
import { Clock, Effect, Exit, Layer, Option } from "effect";
import { TestClock } from "effect/testing";
import { AccessTokenClaims } from "../../src/auth/AuthApi.ts";
import { AccessTokens } from "../../src/auth/Tokens.ts";
import { AgentGrants } from "../../src/core/AgentGrants.ts";
import { CoreDb } from "../../src/core/CoreDb.ts";
import { Devices } from "../../src/core/Devices.ts";
import { OAuthClients } from "../../src/core/OAuthClients.ts";
import { agentGrants, agentTokens } from "../../src/core/Schema.ts";
import { Users } from "../../src/core/Users.ts";
import type { Deployment } from "../../src/Deployment.ts";
import {
  agentAccessTokenLifetime,
  agentRefreshTokenLifetime,
  type AgentTokenPair,
  AgentTokens,
  authorizationCodeLifetime,
  type CodeExchange,
  TokenRequestError,
} from "../../src/oauth/AgentTokens.ts";
import { type RateLimitName, RateLimits } from "../../src/RateLimits.ts";
import { TestSessionKey } from "../auth/TestAuth.ts";
import { type Handler, withApi } from "../TestApi.ts";
import { type Approval, approve, healthResource, TestAgents } from "./TestAgents.ts";

const minute = 60 * 1000;
const day = 24 * 60 * minute;

const exchange = (approval: Approval, overrides: Partial<CodeExchange> = {}) =>
  AgentTokens.use((tokens) =>
    tokens.exchangeCode({
      code: approval.code,
      clientId: approval.clientId,
      redirectUri: approval.redirectUri,
      codeVerifier: approval.verifier,
      resource: Option.some(approval.resource),
      ...overrides,
    }),
  );

const refresh = (
  approval: Pick<Approval, "clientId">,
  pair: Pick<AgentTokenPair, "refreshToken">,
  options: { readonly resource?: string; readonly scope?: string } = {},
) =>
  AgentTokens.use((tokens) =>
    tokens.refresh({
      refreshToken: pair.refreshToken,
      clientId: approval.clientId,
      resource: Option.fromNullishOr(options.resource),
      scope: Option.fromNullishOr(options.scope),
    }),
  );

const verify = (pair: Pick<AgentTokenPair, "accessToken">, resource = healthResource) =>
  AgentTokens.use((tokens) => tokens.verify(pair.accessToken, resource));

/** `effect` fails with a `TokenRequestError` of `error`. */
const refused = <A, E, R>(effect: Effect.Effect<A, E, R>, error: TokenRequestError["error"]) =>
  Effect.gen(function* () {
    const failure = yield* Effect.flip(effect);
    assert.instanceOf(failure, TokenRequestError);
    assert.strictEqual((failure as TokenRequestError).error, error);
  });

/** `verify` refuses the access token, for `reason`. */
const rejected = (
  pair: Pick<AgentTokenPair, "accessToken">,
  reason: "invalid" | "expired",
  resource = healthResource,
) =>
  Effect.gen(function* () {
    const failure = yield* Effect.flip(verify(pair, resource));
    assert.deepInclude(failure, { _tag: "InvalidAgentToken", reason });
  });

const grantCount = Effect.gen(function* () {
  const db = yield* CoreDb;
  return (yield* db.select().from(agentGrants).pipe(Effect.orDie)).length;
});

describe("AgentTokens: authorization codes", () => {
  it.effect("exchange for tokens that only the grant's MCP server accepts", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const pair = yield* exchange(approval);
      assert.match(pair.accessToken, /^lma_[\w-]{43}$/);
      assert.match(pair.refreshToken, /^lmr_[\w-]{43}$/);
      assert.strictEqual(pair.expiresIn, 3600);
      assert.strictEqual(pair.scope, "health:read");

      const grant = yield* verify(pair);
      assert.deepInclude(grant, {
        userId: approval.userId,
        clientId: approval.clientId,
        clientName: "Claude Code",
        clientDomain: "claude.ai",
        redirectHost: "localhost",
        scopes: ["health:read"],
        resource: healthResource,
      });
      assert.match(grant.id, /^agr_/);

      // The audience check: another app's server, or another stage's, refuses it.
      yield* rejected(pair, "invalid", "https://mcp.lil.tech/mail");
      yield* rejected(pair, "invalid", "https://mcp.staging.lil.tech/health");
      // A refresh token isn't a bearer token.
      yield* rejected({ accessToken: pair.refreshToken }, "invalid");

      // Only hashes are stored.
      const db = yield* CoreDb;
      const stored = yield* db.select().from(agentTokens).pipe(Effect.orDie);
      assert.strictEqual(stored.length, 2);
      for (const row of stored) {
        assert.match(row.tokenHash, /^[0-9a-f]{64}$/);
        assert.notInclude([pair.accessToken, pair.refreshToken], row.tokenHash);
      }
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("take the authorization's resource when the request names none", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const pair = yield* exchange(approval, { resource: Option.none() });
      yield* verify(pair);
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("need the verifier the challenge was made from, with S256 only", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      yield* refused(exchange(approval, { codeVerifier: "x".repeat(43) }), "invalid_grant");
      // Too short to be a verifier, or not one's characters.
      yield* refused(exchange(approval, { codeVerifier: "short" }), "invalid_grant");
      yield* refused(
        exchange(approval, { codeVerifier: `${approval.verifier.slice(0, -1)}!` }),
        "invalid_grant",
      );

      // A `plain` challenge is the verifier itself, which S256 never matches.
      const plain = yield* approve({ challenge: (verifier) => verifier });
      yield* refused(exchange(plain), "invalid_grant");

      // A wrong verifier doesn't use the code up.
      yield* exchange(approval);
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("must come from the authorization's client, redirect URI and resource", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const other = yield* (yield* OAuthClients).register({
        name: "Inspector",
        clientUri: null,
        redirectUris: [approval.redirectUri],
        applicationType: "native",
      });
      yield* refused(exchange(approval, { clientId: other.clientId }), "invalid_grant");
      // Exactly the one authorized: not another port, even on loopback.
      yield* refused(
        exchange(approval, { redirectUri: "http://localhost:53713/callback" }),
        "invalid_grant",
      );
      yield* refused(
        exchange(approval, { resource: Option.some("https://mcp.lil.tech/mail") }),
        "invalid_target",
      );
      yield* refused(
        exchange(approval, { resource: Option.some("https://mcp.lil.tech/health/") }),
        "invalid_target",
      );
      yield* exchange(approval);
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("work for 60 seconds", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const late = yield* approve();
      yield* TestClock.adjust(authorizationCodeLifetime - 1);
      yield* exchange(approval);
      yield* TestClock.adjust(1);
      yield* refused(exchange(late), "invalid_grant");
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("work once, and redeeming one again ends the grant it made", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const pair = yield* exchange(approval);
      assert.strictEqual(yield* grantCount, 1);
      yield* refused(exchange(approval), "invalid_grant");
      assert.strictEqual(yield* grantCount, 0);
      yield* rejected(pair, "invalid");
      yield* refused(refresh(approval, pair), "invalid_grant");
      yield* refused(exchange(approval, { code: "unknown" }), "invalid_grant");
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("make one grant when redeemed twice at once", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const results = yield* Effect.all([exchange(approval), exchange(approval)], {
        concurrency: "unbounded",
        mode: "result",
      });
      assert.isAtMost(results.filter((result) => result._tag === "Success").length, 1);
      assert.isAtMost(yield* grantCount, 1);
    }).pipe(Effect.provide(TestAgents)),
  );
});

describe("AgentTokens: refresh tokens", () => {
  it.effect("rotate, keeping the grant's scope and resource", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const first = yield* exchange(approval);
      const grant = yield* verify(first);
      yield* TestClock.adjust(30 * minute);
      const second = yield* refresh(approval, first, { resource: healthResource });
      assert.notStrictEqual(second.refreshToken, first.refreshToken);
      assert.strictEqual(second.scope, "health:read");
      assert.strictEqual((yield* verify(second)).id, grant.id);
      // The old access token keeps its hour.
      yield* verify(first);

      // The next one, asked for the same scope.
      const third = yield* refresh(approval, second, { scope: "health:read" });
      yield* verify(third);
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("never change scope, resource or client", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const pair = yield* exchange(approval);
      yield* refused(refresh(approval, pair, { scope: "health:read mail:read" }), "invalid_scope");
      yield* refused(
        refresh(approval, pair, { resource: "https://mcp.lil.tech/mail" }),
        "invalid_target",
      );
      yield* refused(refresh({ clientId: "cli_other" }, pair), "invalid_grant");
      yield* refused(refresh(approval, { refreshToken: pair.accessToken }), "invalid_grant");
      yield* refused(refresh(approval, { refreshToken: "lmr_unknown" }), "invalid_grant");
      // None of that used the token up.
      yield* refresh(approval, pair);
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("keep working until the new pair is used, each retry replacing the unused pair", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const first = yield* exchange(approval);
      // The response is lost, and the agent tries again.
      const lost = yield* refresh(approval, first);
      yield* TestClock.adjust(1);
      const retried = yield* refresh(approval, first);
      // The unused pair from the first try is gone.
      yield* rejected(lost, "invalid");
      yield* refused(refresh(approval, lost), "invalid_grant");
      assert.strictEqual(yield* grantCount, 1, "a dropped pair doesn't end the grant");

      // Once the new pair is used, the old token is dead, and presenting it is reuse.
      yield* verify(retried);
      yield* refused(refresh(approval, first), "invalid_grant");
      assert.strictEqual(yield* grantCount, 0);
      yield* rejected(retried, "invalid");
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("end the grant when one is reused after its successor was refreshed", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const first = yield* exchange(approval);
      const second = yield* refresh(approval, first);
      const third = yield* refresh(approval, second);
      yield* verify(third);
      // A stolen copy of the first.
      yield* refused(refresh(approval, first), "invalid_grant");
      yield* rejected(third, "invalid");
      yield* refused(refresh(approval, third), "invalid_grant");
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("expire 90 days after they're issued, and access tokens after an hour", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const first = yield* exchange(approval);
      yield* TestClock.adjust(agentAccessTokenLifetime - 1);
      yield* verify(first);
      yield* TestClock.adjust(1);
      yield* rejected(first, "expired");

      // A refresh starts another 90 days.
      yield* TestClock.adjust(agentRefreshTokenLifetime - agentAccessTokenLifetime - 1);
      const second = yield* refresh(approval, first);
      yield* TestClock.adjust(agentRefreshTokenLifetime);
      yield* refused(refresh(approval, second), "invalid_grant");
      yield* rejected(second, "expired");
    }).pipe(Effect.provide(TestAgents)),
  );
});

describe("AgentTokens: revoking", () => {
  it.effect("a refresh token ends its grant, an access token only itself", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const tokens = yield* AgentTokens;
      const first = yield* exchange(approval);
      const second = yield* refresh(approval, first);
      yield* tokens.revoke(second.accessToken, Option.some(approval.clientId));
      yield* rejected(second, "invalid");
      yield* verify(first);

      // Another client's revocation, and unknown tokens, are ignored.
      yield* tokens.revoke(second.refreshToken, Option.some("cli_other"));
      yield* tokens.revoke("lmr_unknown", Option.none());
      yield* tokens.revoke("nonsense", Option.none());
      const third = yield* refresh(approval, second);

      yield* tokens.revoke(third.refreshToken, Option.none());
      assert.strictEqual(yield* grantCount, 0);
      yield* rejected(third, "invalid");
      yield* rejected(first, "invalid");
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("deleting the account deletes its grants and tokens", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const pair = yield* exchange(approval);
      yield* (yield* Users).delete(approval.userId);
      yield* rejected(pair, "invalid");
      const db = yield* CoreDb;
      assert.strictEqual((yield* db.select().from(agentTokens).pipe(Effect.orDie)).length, 0);
    }).pipe(Effect.provide(TestAgents)),
  );
});

describe("AgentTokens.verify", () => {
  it.effect("records that a grant was used at most every 5 minutes", () =>
    Effect.gen(function* () {
      const approval = yield* approve();
      const pair = yield* exchange(approval);
      const created = (yield* verify(pair)).lastUsedAt;
      yield* TestClock.adjust(5 * minute - 1);
      assert.strictEqual((yield* verify(pair)).lastUsedAt, created);
      yield* TestClock.adjust(1);
      yield* verify(pair);
      assert.strictEqual((yield* verify(pair)).lastUsedAt, created + 5 * minute);
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("never accepts the apps' access tokens", () =>
    Effect.gen(function* () {
      const user = yield* (yield* Users).create({ displayName: "Ada" });
      const device = yield* (yield* Devices).create({
        userId: user.id,
        app: "health-ios",
        platform: "ios",
        name: null,
      });
      const { token } = yield* (yield* AccessTokens).sign(
        new AccessTokenClaims({
          userId: user.id,
          deviceId: device.id,
          sessionId: "ses_0000000000aaaaaaaaaaaaaaaa" as AccessTokenClaims["sessionId"],
        }),
      );
      yield* rejected({ accessToken: token }, "invalid");
      yield* rejected({ accessToken: `lma_${token}` }, "invalid");
    }).pipe(
      Effect.provide(TestAgents),
      Effect.provide(AccessTokens.layer.pipe(Layer.provide(TestSessionKey))),
    ),
  );
});

describe("Cleanup", () => {
  it.effect("deletes expired tokens and authorizations, and grants that have ended", () =>
    Effect.gen(function* () {
      const grants = yield* AgentGrants;
      const kept = yield* approve();
      const keptPair = yield* exchange(kept);
      const ended = yield* approve({ clientId: kept.clientId });
      yield* exchange(ended);
      // Approved, never redeemed.
      yield* approve({ clientId: kept.clientId });
      yield* TestClock.adjust(10 * minute);
      const now = () => Clock.currentTimeMillis;
      assert.deepStrictEqual(yield* grants.deleteExpired(yield* now()), {
        tokens: 0,
        authorizations: 3,
        grants: 0,
      });

      yield* TestClock.adjust(2 * agentAccessTokenLifetime);
      const second = yield* refresh(kept, keptPair);
      assert.deepStrictEqual(yield* grants.deleteExpired(yield* now()), {
        tokens: 2,
        authorizations: 0,
        grants: 0,
      });

      // The other grant's refresh token runs out.
      yield* TestClock.adjust(agentRefreshTokenLifetime - 2 * agentAccessTokenLifetime);
      // That grant's tokens, and the first one's replaced refresh token and latest access token.
      assert.deepStrictEqual(yield* grants.deleteExpired(yield* now()), {
        tokens: 3,
        authorizations: 0,
        grants: 1,
      });
      yield* refresh(kept, second);
      assert.strictEqual(yield* grantCount, 1);
    }).pipe(Effect.provide(TestAgents)),
  );

  it.effect("keeps clients with a grant, and deletes the rest as they go unused", () =>
    Effect.gen(function* () {
      const clients = yield* OAuthClients;
      const metadata = {
        name: "Inspector",
        clientUri: null,
        redirectUris: ["http://localhost:6274/oauth/callback"],
        applicationType: "native" as const,
      };
      const unused = yield* clients.register(metadata);
      const connected = yield* clients.register(metadata);
      const approval = yield* approve({
        clientId: connected.clientId,
        redirectUri: "http://localhost:6274/oauth/callback",
      });
      const pair = yield* exchange(approval);
      const abandoned = yield* clients.register(metadata);
      yield* TestClock.adjust(12 * 60 * minute);
      // Used for an authorization that was never allowed.
      yield* clients.resolve(abandoned.clientId);

      yield* TestClock.adjust(12 * 60 * minute + 1);
      assert.strictEqual(yield* clients.deleteUnused, 1);
      assert.isTrue(Exit.isFailure(yield* clients.resolve(unused.clientId).pipe(Effect.exit)));
      yield* TestClock.adjust(12 * 60 * minute);
      assert.strictEqual(yield* clients.deleteUnused, 1, "a day after it was last used");

      // A client with a grant stays, however long; once the grant is revoked, it goes.
      yield* TestClock.adjust(100 * day);
      assert.strictEqual(yield* clients.deleteUnused, 0);
      yield* (yield* AgentTokens).revoke(pair.refreshToken, Option.none());
      assert.strictEqual(yield* clients.deleteUnused, 1);
    }).pipe(Effect.provide(TestAgents)),
  );
});

// The endpoints, as agents call them.

const preview: Deployment["Service"] = { environment: "preview", version: "1" };
const previewOrigin = "https://lil-api-pr-12.example.workers.dev";
const previewResource = `${previewOrigin}/health`;

const post = (
  handler: Handler,
  path: string,
  params: Record<string, string> | string,
  headers: Record<string, string> = {},
) =>
  Effect.promise(async () => {
    const response = await handler(
      new Request(`${previewOrigin}${path}`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", ...headers },
        body: typeof params === "string" ? params : new URLSearchParams(params).toString(),
      }),
    );
    const text = await response.text();
    return {
      status: response.status,
      headers: response.headers,
      body: (text === "" ? undefined : JSON.parse(text)) as Record<string, unknown> | undefined,
    };
  });

const codeParams = (approval: Approval) => ({
  grant_type: "authorization_code",
  code: approval.code,
  client_id: approval.clientId,
  redirect_uri: approval.redirectUri,
  code_verifier: approval.verifier,
  resource: approval.resource,
});

const verifyIn = (token: string, resource = previewResource) =>
  AgentTokens.use((tokens) => tokens.verify(token, resource)).pipe(
    Effect.provide(
      AgentTokens.layer.pipe(Layer.provide(Layer.succeed(RateLimits, RateLimits.unlimited))),
    ),
  );

describe("POST /oauth/token", () => {
  it.live("exchanges a code and refreshes, as Claude sends them", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const approval = yield* approve({ resource: previewResource });
          const response = yield* post(handler, "/oauth/token", codeParams(approval));
          assert.strictEqual(response.status, 200);
          assert.strictEqual(response.headers.get("cache-control"), "no-store");
          assert.deepStrictEqual(Object.keys(response.body ?? {}).sort(), [
            "access_token",
            "expires_in",
            "refresh_token",
            "scope",
            "token_type",
          ]);
          assert.deepInclude(response.body, {
            token_type: "Bearer",
            expires_in: 3600,
            scope: "health:read",
          });
          const grant = yield* verifyIn(String(response.body?.["access_token"]));
          assert.strictEqual(grant.userId, approval.userId);

          const refreshed = yield* post(handler, "/oauth/token", {
            grant_type: "refresh_token",
            refresh_token: String(response.body?.["refresh_token"]),
            client_id: approval.clientId,
          });
          assert.strictEqual(refreshed.status, 200);
          assert.strictEqual(refreshed.headers.get("cache-control"), "no-store");
          yield* verifyIn(String(refreshed.body?.["access_token"]));

          // Used again.
          const again = yield* post(handler, "/oauth/token", codeParams(approval));
          assert.strictEqual(again.status, 400);
          assert.strictEqual(again.headers.get("cache-control"), "no-store");
          assert.deepInclude(again.body, { error: "invalid_grant" });
        }),
      preview,
    ),
  );

  it.live("answers malformed requests with RFC 6749's errors", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const approval = yield* approve({ resource: previewResource });
          const params = codeParams(approval);
          const error = (body: Record<string, unknown> | undefined) => body?.["error"];
          const cases: ReadonlyArray<
            readonly [string, Record<string, string> | string, string, Record<string, string>?]
          > = [
            ["no grant type", { ...params, grant_type: "" }, "invalid_request"],
            [
              "client credentials",
              { ...params, grant_type: "client_credentials" },
              "unsupported_grant_type",
            ],
            ["no client", { ...params, client_id: "" }, "invalid_request"],
            ["no verifier", { ...params, code_verifier: "" }, "invalid_request"],
            ["no redirect URI", { ...params, redirect_uri: "" }, "invalid_request"],
            [
              "a parameter twice",
              `${new URLSearchParams(params).toString()}&code=again`,
              "invalid_request",
            ],
            [
              "JSON",
              JSON.stringify(params),
              "invalid_request",
              { "content-type": "application/json" },
            ],
            ["too large", { ...params, padding: "x".repeat(9000) }, "invalid_request"],
            ["an unknown code", { ...params, code: "nope" }, "invalid_grant"],
            [
              "another resource",
              { ...params, resource: "https://mcp.lil.tech/health" },
              "invalid_target",
            ],
            [
              "an unknown refresh token",
              { grant_type: "refresh_token", refresh_token: "lmr_x", client_id: approval.clientId },
              "invalid_grant",
            ],
          ];
          for (const [name, body, expected, headers] of cases) {
            const response = yield* post(handler, "/oauth/token", body, headers);
            assert.strictEqual(response.status, 400, name);
            assert.strictEqual(error(response.body), expected, name);
            assert.isString(response.body?.["error_description"], name);
          }
          // None of them used the code up.
          assert.strictEqual((yield* post(handler, "/oauth/token", params)).status, 200);
        }),
      preview,
    ),
  );

  it.live("lets any web origin call it and revoke, without credentials", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const origin = "http://localhost:6274";
          for (const path of ["/oauth/token", "/oauth/revoke"]) {
            const preflight = yield* Effect.promise(() =>
              handler(
                new Request(`${previewOrigin}${path}`, {
                  method: "OPTIONS",
                  headers: {
                    origin,
                    "access-control-request-method": "POST",
                    "access-control-request-headers": "content-type",
                  },
                }),
              ),
            );
            assert.strictEqual(preflight.status, 204, path);
            assert.strictEqual(preflight.headers.get("access-control-allow-origin"), "*", path);
            assert.strictEqual(preflight.headers.get("access-control-allow-methods"), "POST");
            assert.isNull(preflight.headers.get("access-control-allow-credentials"));
            const response = yield* post(handler, path, { token: "x" }, { origin });
            assert.strictEqual(response.headers.get("access-control-allow-origin"), "*", path);
          }
        }),
      preview,
    ),
  );

  it.live("limits exchanges per client and refreshes per grant", () => {
    const counts = new Map<string, number>();
    const counter = (limit: RateLimitName, max: number) => (key: string) =>
      Effect.sync(() => {
        const count = (counts.get(`${limit}/${key}`) ?? 0) + 1;
        counts.set(`${limit}/${key}`, count);
        return count <= max;
      });
    const limits = RateLimits.make({
      signIn: counter("signIn", Infinity),
      user: counter("user", Infinity),
      refresh: counter("refresh", Infinity),
      clientRegistration: counter("clientRegistration", Infinity),
      agentToken: counter("agentToken", 2),
    });
    return withApi(
      (handler) =>
        Effect.gen(function* () {
          const first = yield* approve({ resource: previewResource });
          const second = yield* approve({ resource: previewResource, clientId: first.clientId });
          const third = yield* approve({ resource: previewResource, clientId: first.clientId });
          const pair = yield* post(handler, "/oauth/token", codeParams(first));
          assert.strictEqual(pair.status, 200);
          assert.strictEqual(
            (yield* post(handler, "/oauth/token", codeParams(second))).status,
            200,
          );
          const limited = yield* post(handler, "/oauth/token", codeParams(third));
          assert.strictEqual(limited.status, 429);
          assert.strictEqual(limited.headers.get("retry-after"), "60");

          // Refreshes count per grant, apart from the client's exchanges.
          const refreshWith = (token: unknown) =>
            post(handler, "/oauth/token", {
              grant_type: "refresh_token",
              refresh_token: String(token),
              client_id: first.clientId,
            });
          const once = yield* refreshWith(pair.body?.["refresh_token"]);
          assert.strictEqual(once.status, 200);
          const twice = yield* refreshWith(once.body?.["refresh_token"]);
          assert.strictEqual(twice.status, 200);
          assert.strictEqual((yield* refreshWith(twice.body?.["refresh_token"])).status, 429);
        }),
      preview,
      limits,
    );
  });

  it.live("isn't in prod yet", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          for (const path of ["/oauth/token", "/oauth/revoke"]) {
            const response = yield* Effect.promise(() =>
              handler(
                new Request(`https://api.lil.tech${path}`, {
                  method: "POST",
                  headers: { "content-type": "application/x-www-form-urlencoded" },
                  body: "token=x",
                }),
              ),
            );
            assert.strictEqual(response.status, 404, path);
          }
        }),
      { environment: "prod", version: "1" },
    ),
  );
});

describe("POST /oauth/revoke", () => {
  it.live("answers 200, known token or not, and ends the grant for a refresh token", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const approval = yield* approve({ resource: previewResource });
          const pair = (yield* post(handler, "/oauth/token", codeParams(approval))).body;
          const accessToken = String(pair?.["access_token"]);
          for (const token of ["nope", "lmr_unknown", "lma_unknown"]) {
            const response = yield* post(handler, "/oauth/revoke", { token });
            assert.strictEqual(response.status, 200, token);
            assert.isUndefined(response.body);
          }
          yield* verifyIn(accessToken);
          const revoked = yield* post(handler, "/oauth/revoke", {
            token: String(pair?.["refresh_token"]),
            token_type_hint: "refresh_token",
            client_id: approval.clientId,
          });
          assert.strictEqual(revoked.status, 200);
          const failure = yield* Effect.flip(verifyIn(accessToken));
          assert.deepInclude(failure, { _tag: "InvalidAgentToken", reason: "invalid" });

          const missing = yield* post(handler, "/oauth/revoke", { client_id: approval.clientId });
          assert.strictEqual(missing.status, 400);
          assert.deepInclude(missing.body, { error: "invalid_request" });
        }),
      preview,
    ),
  );
});

describe("Agents' and apps' tokens", () => {
  it.live("an agent's access token doesn't work on the apps' API", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const approval = yield* approve({ resource: previewResource });
          const pair = (yield* post(handler, "/oauth/token", codeParams(approval))).body;
          for (const token of [pair?.["access_token"], pair?.["refresh_token"]]) {
            const response = yield* Effect.promise(() =>
              handler(
                new Request(`${previewOrigin}/v1/me`, {
                  headers: { authorization: `Bearer ${String(token)}` },
                }),
              ),
            );
            assert.strictEqual(response.status, 401);
          }
        }),
      preview,
    ),
  );
});
