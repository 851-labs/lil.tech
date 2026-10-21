import { assert, describe, it } from "@effect/vitest";
import { Effect, Option } from "effect";
import { Auth } from "../../src/auth/Auth.ts";
import { type ConsentType, Consents } from "../../src/core/Consents.ts";
import { CoreDb } from "../../src/core/CoreDb.ts";
import { agentTokens } from "../../src/core/Schema.ts";
import { Devices } from "../../src/core/Devices.ts";
import type { UserId } from "../../src/core/Ids.ts";
import { Users } from "../../src/core/Users.ts";
import type { Deployment } from "../../src/Deployment.ts";
import { RateLimits } from "../../src/RateLimits.ts";
import { agentAccessLogPageSize } from "../../src/oauth/AgentsApi.ts";
import { type AgentAccess, appendAgentAccess } from "../../src/store/AgentAccessLog.ts";
import { UserStores } from "../../src/store/UserStores.ts";
import { inSession, postMcp, sessionless, sessionProtocol } from "../mcp/TestMcp.ts";
import { TestStores } from "../store/TestUserStores.ts";
import { type Handler, send, withApi } from "../TestApi.ts";
import { type Approval, approve, WithMail } from "./TestAgents.ts";

// The apps' endpoints for connected agents (851-2852): listing them, their access log, revoking
// one, and turning lil health's agents off. Synthetic users and data only.

const preview: Deployment["Service"] = { environment: "preview", version: "1" };
const previewOrigin = "https://lil-api-pr-12.example.workers.dev";
const healthResource = `${previewOrigin}/health`;
/** Another app's MCP server, which lil health's switch mustn't touch. */
const mailResource = `${previewOrigin}/mail`;

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

/** A user signed in to an app, with its access token. */
const signIn = Effect.gen(function* () {
  const user = yield* (yield* Users).create({ displayName: "Ada" });
  const device = yield* (yield* Devices).create({
    userId: user.id,
    app: "health-ios",
    platform: "ios",
    name: null,
  });
  const tokens = yield* (yield* Auth).issueSession(user.id, device.id);
  return { userId: user.id, accessToken: tokens.accessToken };
}).pipe(Effect.orDie);

/** An app's request to the API. */
const app = (handler: Handler, accessToken: string, method: string, path: string) =>
  send(handler, new Request(`${previewOrigin}${path}`, { method, headers: bearer(accessToken) }));

const form = (handler: Handler, path: string, params: Record<string, string>) =>
  send(
    handler,
    new Request(`${previewOrigin}${path}`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params).toString(),
    }),
  );

/** lil's combined MCP server on the preview, as it's stored: the origin. */
const combinedResource = previewOrigin;

/**
 * Connects Claude Code for `userId`, as allowing it on the consent page and the token endpoint do,
 * with `scopes` (`health:read`) granted.
 */
const connect = (
  handler: Handler,
  userId: UserId,
  resource = healthResource,
  scopes?: ReadonlyArray<string>,
) =>
  Effect.gen(function* () {
    const approval = yield* approve({
      userId,
      resource,
      ...(scopes === undefined ? {} : { scopes }),
    });
    const tokens = yield* form(handler, "/oauth/token", {
      grant_type: "authorization_code",
      code: approval.code,
      client_id: approval.clientId,
      redirect_uri: approval.redirectUri,
      code_verifier: approval.verifier,
      resource,
    });
    assert.strictEqual(tokens.status, 200);
    const body = tokens.body as Record<string, string>;
    return {
      ...approval,
      accessToken: body["access_token"]!,
      refreshToken: body["refresh_token"]!,
    };
  });

/** A request to lil health's MCP server. */
const callMcp = (
  handler: Handler,
  accessToken: string,
  method: string,
  params: Record<string, unknown> = {},
) => {
  const request = sessionless(method, params);
  return postMcp(handler, healthResource, request.body, {
    ...request.headers,
    ...bearer(accessToken),
  });
};

/** A tool call at lil health's MCP server. */
const callSummary = (handler: Handler, accessToken: string) =>
  callMcp(handler, accessToken, "tools/call", { name: "summary", arguments: {} });

/** A request to the combined MCP server. */
const callCombined = (
  handler: Handler,
  accessToken: string,
  method: string,
  params: Record<string, unknown> = {},
) => {
  const request = sessionless(method, params);
  return postMcp(handler, `${combinedResource}/`, request.body, {
    ...request.headers,
    ...bearer(accessToken),
  });
};

/** The tools the combined server lists for an agent. */
const combinedTools = (handler: Handler, accessToken: string) =>
  Effect.gen(function* () {
    const list = yield* callCombined(handler, accessToken, "tools/list");
    assert.strictEqual(list.status, 200);
    const result = list.message?.["result"] as { tools: ReadonlyArray<{ name: string }> };
    return result.tools.map((tool) => tool.name);
  });

interface AgentBody {
  readonly id: string;
  readonly name: string | null;
  readonly app: string | null;
  readonly apps: ReadonlyArray<string>;
  readonly resource: string;
}

const agentsOf = (body: unknown) => (body as { agents: ReadonlyArray<AgentBody> }).agents;

interface LogBody {
  readonly entries: ReadonlyArray<Record<string, unknown>>;
  readonly nextBefore: number | null;
}

describe("GET /v1/me/agents", () => {
  it.live("lists the account's connected agents, and only its own", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const bob = yield* signIn;
          const empty = yield* app(handler, ada.accessToken, "GET", "/v1/me/agents");
          assert.deepStrictEqual(empty, { status: 200, body: { agents: [] } });

          yield* connect(handler, ada.userId);
          yield* connect(handler, bob.userId);
          const listed = yield* app(handler, ada.accessToken, "GET", "/v1/me/agents");
          assert.strictEqual(listed.status, 200);
          const [agent, ...others] = agentsOf(listed.body);
          assert.deepStrictEqual(others, []);
          assert.match(agent!.id, /^agr_/);
          const { connectedAt, lastUsedAt } = agent as unknown as Record<string, number>;
          assert.isNumber(connectedAt);
          assert.strictEqual(lastUsedAt, connectedAt);
          // Not used yet.
          assert.deepStrictEqual(agent, {
            id: agent!.id,
            name: "Claude Code",
            domain: "claude.ai",
            redirectHost: "localhost",
            resource: healthResource,
            app: "health",
            apps: ["health"],
            connectedAt,
            lastUsedAt,
            firstUsedAt: null,
          } as AgentBody);
        }),
      preview,
    ),
  );

  it.live("records an agent's first read at once, which listing tools doesn't count as", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const agent = yield* connect(handler, ada.userId);
          const used = Effect.gen(function* () {
            const [listed] = agentsOf(
              (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
            );
            return listed as unknown as {
              readonly connectedAt: number;
              readonly lastUsedAt: number;
              readonly firstUsedAt: number | null;
            };
          });
          // Agents list the tools as they connect, without reading anything.
          assert.strictEqual(
            (yield* callMcp(handler, agent.accessToken, "tools/list")).status,
            200,
          );
          // A call the server refuses, in a session it doesn't know, reads nothing either.
          const refused = yield* postMcp(
            handler,
            healthResource,
            inSession("tools/call", { name: "summary", arguments: {} }),
            {
              ...bearer(agent.accessToken),
              "mcp-protocol-version": sessionProtocol,
              "mcp-session-id": "00000000-0000-4000-8000-000000000000",
            },
          );
          assert.strictEqual(refused.status, 404);
          const connected = yield* used;
          assert.isNull(connected.firstUsedAt);
          assert.strictEqual(connected.lastUsedAt, connected.connectedAt);

          // A read within the first 5 minutes, which `lastUsedAt` alone would miss.
          assert.strictEqual((yield* callSummary(handler, agent.accessToken)).status, 200);
          const read = yield* used;
          assert.isNotNull(read.firstUsedAt);
          assert.isAtLeast(read.firstUsedAt!, read.connectedAt);
          assert.strictEqual(read.lastUsedAt, read.firstUsedAt);

          // Only the first is recorded.
          yield* Effect.sleep("5 millis");
          assert.strictEqual((yield* callSummary(handler, agent.accessToken)).status, 200);
          assert.deepStrictEqual(yield* used, read);
        }),
      preview,
    ),
  );

  it.live("names the apps each agent reads, through an app's server or the combined one", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          yield* connect(handler, ada.userId);
          yield* connect(handler, ada.userId, combinedResource, ["health:read", "mail:read"]);
          yield* connect(handler, ada.userId, combinedResource, ["mail:read"]);
          yield* connect(handler, ada.userId, `${combinedResource}/elsewhere`);
          assert.sameDeepMembers(
            agentsOf((yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body).map(
              (agent) => [agent.resource, agent.app, agent.apps],
            ),
            [
              [healthResource, "health", ["health"]],
              [combinedResource, null, ["health", "mail"]],
              [combinedResource, null, ["mail"]],
              // A server this deployment doesn't know.
              [`${combinedResource}/elsewhere`, null, []],
            ],
          );
        }),
      preview,
      RateLimits.unlimited,
      WithMail,
    ),
  );

  it.live("leaves out an agent whose access ended", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          yield* connect(handler, ada.userId);
          // Its refresh token expired (90 days unused); the daily cleanup deletes it later.
          yield* (yield* CoreDb).update(agentTokens).set({ expiresAt: 1 }).pipe(Effect.orDie);
          assert.deepStrictEqual(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
            { agents: [] },
          );
        }),
      preview,
    ),
  );

  it.live("needs the app's access token", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const agent = yield* connect(handler, ada.userId);
          // An agent's token is never the app's.
          const refused = yield* app(handler, agent.accessToken, "GET", "/v1/me/agents");
          assert.strictEqual(refused.status, 401);
          const missing = yield* send(handler, new Request(`${previewOrigin}/v1/me/agents`));
          assert.strictEqual(missing.status, 401);
        }),
      preview,
    ),
  );
});

describe("DELETE /v1/me/agents/{id}", () => {
  it.live("revokes an agent at once, and is idempotent", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const agent = yield* connect(handler, ada.userId);
          assert.strictEqual((yield* callSummary(handler, agent.accessToken)).status, 200);
          const [listed] = agentsOf(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
          );

          const path = `/v1/me/agents/${listed!.id}`;
          assert.strictEqual((yield* app(handler, ada.accessToken, "DELETE", path)).status, 204);
          // Its next request is refused, and it can't refresh its way back.
          assert.strictEqual((yield* callSummary(handler, agent.accessToken)).status, 401);
          const refreshed = yield* form(handler, "/oauth/token", {
            grant_type: "refresh_token",
            refresh_token: agent.refreshToken,
            client_id: agent.clientId,
          });
          assert.strictEqual(refreshed.status, 400);
          assert.deepInclude(refreshed.body, { error: "invalid_grant" });
          assert.deepStrictEqual(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
            { agents: [] },
          );
          // Again: nothing left to revoke, and the same answer.
          assert.strictEqual((yield* app(handler, ada.accessToken, "DELETE", path)).status, 204);
        }),
      preview,
    ),
  );

  it.live("leaves another account's agent alone", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const bob = yield* signIn;
          const agent = yield* connect(handler, bob.userId);
          const [bobs] = agentsOf(
            (yield* app(handler, bob.accessToken, "GET", "/v1/me/agents")).body,
          );
          const revoked = yield* app(
            handler,
            ada.accessToken,
            "DELETE",
            `/v1/me/agents/${bobs!.id}`,
          );
          // The same answer as for one that's gone, so nobody learns another's grant exists.
          assert.strictEqual(revoked.status, 204);
          assert.strictEqual((yield* callSummary(handler, agent.accessToken)).status, 200);
          const malformed = yield* app(handler, ada.accessToken, "DELETE", "/v1/me/agents/nope");
          assert.strictEqual(malformed.status, 400);
        }),
      preview,
    ),
  );
});

describe("GET /v1/me/agents/access-log", () => {
  const access = (overrides: Partial<AgentAccess> = {}): AgentAccess => ({
    grantId: "agr_01jbtest000000000000000000",
    clientName: "Claude",
    tool: "metric",
    types: ["HKQuantityTypeIdentifierStepCount"],
    range: "W",
    date: "2026-10-20",
    outcome: "ok",
    rows: 7,
    ...overrides,
  });

  it.live("shows each tool call an agent made, newest first, after it's revoked too", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const agent = yield* connect(handler, ada.userId);
          yield* callSummary(handler, agent.accessToken);
          yield* callSummary(handler, agent.accessToken);
          const [listed] = agentsOf(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
          );
          yield* app(handler, ada.accessToken, "DELETE", `/v1/me/agents/${listed!.id}`);

          const log = yield* app(handler, ada.accessToken, "GET", "/v1/me/agents/access-log");
          assert.strictEqual(log.status, 200);
          const { entries, nextBefore } = log.body as LogBody;
          assert.isNull(nextBefore);
          assert.lengthOf(entries, 2);
          const [newest, oldest] = entries;
          assert.isAbove(newest!["id"] as number, oldest!["id"] as number);
          assert.deepStrictEqual(newest, {
            id: newest!["id"],
            at: newest!["at"],
            agentId: listed!.id,
            agentName: "Claude Code",
            tool: "summary",
            types: null,
            range: null,
            date: null,
            outcome: "ok",
            rows: 6,
          });
        }),
      preview,
    ),
  );

  it.live("pages 100 at a time", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          // Opens the store, so its tables exist.
          assert.deepStrictEqual(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents/access-log")).body,
            { entries: [], nextBefore: null },
          );
          const sql = (yield* TestStores).sqlFor(ada.userId)!;
          const total = agentAccessLogPageSize + 50;
          for (let at = 1; at <= total; at++) {
            appendAgentAccess(sql, access({ rows: at }), at);
          }
          const first = (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents/access-log"))
            .body as LogBody;
          assert.lengthOf(first.entries, agentAccessLogPageSize);
          assert.deepStrictEqual(first.entries[0], {
            id: total,
            at: total,
            agentId: "agr_01jbtest000000000000000000",
            agentName: "Claude",
            tool: "metric",
            types: ["HKQuantityTypeIdentifierStepCount"],
            range: "W",
            date: "2026-10-20",
            outcome: "ok",
            rows: total,
          });
          assert.strictEqual(first.nextBefore, first.entries.at(-1)!["id"]);
          const second = (yield* app(
            handler,
            ada.accessToken,
            "GET",
            `/v1/me/agents/access-log?before=${first.nextBefore}`,
          )).body as LogBody;
          assert.deepStrictEqual(
            second.entries.map((entry) => entry["rows"]),
            Array.from({ length: 50 }, (_, index) => 50 - index),
          );
          assert.isNull(second.nextBefore);
          const invalid = yield* app(
            handler,
            ada.accessToken,
            "GET",
            "/v1/me/agents/access-log?before=soon",
          );
          assert.strictEqual(invalid.status, 400);
        }),
      preview,
    ),
  );

  it.live("is refused once the account is deleted", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          yield* (yield* UserStores).forUser(ada.userId).deleteAll();
          const log = yield* app(handler, ada.accessToken, "GET", "/v1/me/agents/access-log");
          assert.strictEqual(log.status, 401);
        }),
      preview,
    ),
  );
});

describe("/v1/me/consents/agents/health", () => {
  it.live("shows lil health's agents consent, and turning it off revokes only its agents", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const consent = () =>
            app(handler, ada.accessToken, "GET", "/v1/me/consents/agents/health");
          assert.deepStrictEqual(yield* consent(), { status: 200, body: { given: null } });
          // Allowing an agent on the consent page records it.
          const given = yield* (yield* Consents).grant(ada.userId, "agents:health", "2026-10-20");
          yield* (yield* Consents).grant(ada.userId, "health", "2026-10-15");
          assert.deepStrictEqual(yield* consent(), {
            status: 200,
            body: { given: { policyVersion: "2026-10-20", grantedAt: given.grantedAt } },
          });

          const health = yield* connect(handler, ada.userId);
          const mail = yield* connect(handler, ada.userId, mailResource);
          // lil health's, connected through another origin than the app's requests come to
          // (`alchemy dev` behind a tunnel): it's still lil health's.
          yield* connect(handler, ada.userId, "https://tunnel.example/health");
          assert.sameDeepMembers(
            agentsOf((yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body).map(
              (agent) => [agent.resource, agent.app],
            ),
            [
              [healthResource, "health"],
              [mailResource, null],
              ["https://tunnel.example/health", "health"],
            ],
          );
          // A code allowed but not yet redeemed, which mustn't become a grant afterwards.
          const pending = yield* approve({ userId: ada.userId, resource: healthResource });

          const off = yield* app(
            handler,
            ada.accessToken,
            "DELETE",
            "/v1/me/consents/agents/health",
          );
          assert.strictEqual(off.status, 204);
          assert.deepStrictEqual((yield* consent()).body, { given: null });
          assert.strictEqual((yield* callSummary(handler, health.accessToken)).status, 401);
          const redeemed = yield* form(handler, "/oauth/token", {
            grant_type: "authorization_code",
            code: pending.code,
            client_id: pending.clientId,
            redirect_uri: pending.redirectUri,
            code_verifier: pending.verifier,
          });
          assert.deepInclude(redeemed, { status: 400 });
          // Another app's agent, and Health consent, stay.
          const left = agentsOf(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
          );
          assert.deepStrictEqual(
            left.map((agent) => [agent.resource, agent.app]),
            [[mailResource, null]],
          );
          const refreshed = yield* form(handler, "/oauth/token", {
            grant_type: "refresh_token",
            refresh_token: mail.refreshToken,
            client_id: mail.clientId,
          });
          assert.strictEqual(refreshed.status, 200);
          assert.isTrue(Option.isSome(yield* (yield* Consents).current(ada.userId, "health")));
          // Turning it off again changes nothing.
          assert.strictEqual(
            (yield* app(handler, ada.accessToken, "DELETE", "/v1/me/consents/agents/health"))
              .status,
            204,
          );
        }),
      preview,
    ),
  );
});

describe("Turn Off Agent Access with the combined server", () => {
  /** A user signed in to an app, who allowed agents for lil health and lil mail. */
  const signInWithConsents = Effect.gen(function* () {
    const user = yield* signIn;
    const consents = yield* Consents;
    yield* consents.grant(user.userId, "agents:health", "2026-10-21").pipe(Effect.orDie);
    yield* consents
      .grant(user.userId, "agents:mail" as ConsentType, "2026-10-21")
      .pipe(Effect.orDie);
    return user;
  });

  const turnOffHealth = (handler: Handler, accessToken: string) =>
    app(handler, accessToken, "DELETE", "/v1/me/consents/agents/health");

  it.live("takes lil health away from combined agents, and revokes those left with nothing", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signInWithConsents;
          const both = yield* connect(handler, ada.userId, combinedResource, [
            "health:read",
            "mail:read",
          ]);
          const healthOnly = yield* connect(handler, ada.userId, combinedResource, ["health:read"]);
          const own = yield* connect(handler, ada.userId);
          // Requests allowed but not yet redeemed: one that asked for lil health, which mustn't
          // become a grant afterwards, and one for lil mail alone, which may.
          const asked = yield* approve({
            userId: ada.userId,
            resource: combinedResource,
            scopes: ["health:read", "mail:read"],
          });
          const mailAsked = yield* approve({
            userId: ada.userId,
            resource: combinedResource,
            scopes: ["mail:read"],
          });
          assert.include(yield* combinedTools(handler, both.accessToken), "health.summary");

          assert.strictEqual((yield* turnOffHealth(handler, ada.accessToken)).status, 204);

          // The agent that read both apps reads lil mail alone, from its next request.
          assert.deepStrictEqual(yield* combinedTools(handler, both.accessToken), [
            "mail.summary",
            "mail.search",
          ]);
          const refused = yield* callCombined(handler, both.accessToken, "tools/call", {
            name: "health.summary",
            arguments: {},
          });
          assert.deepInclude(refused.message?.["error"], { code: -32602 });
          const mail = yield* callCombined(handler, both.accessToken, "tools/call", {
            name: "mail.summary",
            arguments: {},
          });
          assert.deepInclude(mail.message?.["result"], { isError: false });
          // A refresh answers with what's left.
          const refreshed = yield* form(handler, "/oauth/token", {
            grant_type: "refresh_token",
            refresh_token: both.refreshToken,
            client_id: both.clientId,
          });
          assert.strictEqual(refreshed.status, 200);
          assert.deepInclude(refreshed.body, { scope: "mail:read" });

          // The one that read only lil health, and lil health's own, are revoked.
          const cutOff = yield* callCombined(handler, healthOnly.accessToken, "tools/list");
          assert.strictEqual(cutOff.status, 401);
          assert.strictEqual((yield* callSummary(handler, own.accessToken)).status, 401);
          const listed = agentsOf(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
          );
          assert.deepStrictEqual(
            listed.map((agent) => [agent.resource, agent.app, agent.apps]),
            [[combinedResource, null, ["mail"]]],
          );

          const redeem = (approval: Approval) =>
            form(handler, "/oauth/token", {
              grant_type: "authorization_code",
              code: approval.code,
              client_id: approval.clientId,
              redirect_uri: approval.redirectUri,
              code_verifier: approval.verifier,
            });
          assert.deepInclude(yield* redeem(asked), { status: 400 });
          assert.deepInclude(yield* redeem(mailAsked), { status: 200 });
        }),
      preview,
      RateLimits.unlimited,
      WithMail,
    ),
  );

  it.live("leaves another account's combined agents alone", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signInWithConsents;
          const bob = yield* signInWithConsents;
          yield* connect(handler, ada.userId, combinedResource, ["health:read"]);
          const bobs = yield* connect(handler, bob.userId, combinedResource, [
            "health:read",
            "mail:read",
          ]);
          assert.strictEqual((yield* turnOffHealth(handler, ada.accessToken)).status, 204);
          assert.deepStrictEqual(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
            { agents: [] },
          );
          assert.deepStrictEqual(
            agentsOf((yield* app(handler, bob.accessToken, "GET", "/v1/me/agents")).body).map(
              (agent) => agent.apps,
            ),
            [["health", "mail"]],
          );
          assert.include(yield* combinedTools(handler, bobs.accessToken), "health.summary");
        }),
      preview,
      RateLimits.unlimited,
      WithMail,
    ),
  );

  it.live("revoking a combined agent disconnects it from every app", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signInWithConsents;
          const both = yield* connect(handler, ada.userId, combinedResource, [
            "health:read",
            "mail:read",
          ]);
          const [listed] = agentsOf(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
          );
          const revoked = yield* app(
            handler,
            ada.accessToken,
            "DELETE",
            `/v1/me/agents/${listed!.id}`,
          );
          assert.strictEqual(revoked.status, 204);
          assert.strictEqual(
            (yield* callCombined(handler, both.accessToken, "tools/list")).status,
            401,
          );
          assert.deepStrictEqual(
            (yield* app(handler, ada.accessToken, "GET", "/v1/me/agents")).body,
            { agents: [] },
          );
        }),
      preview,
      RateLimits.unlimited,
      WithMail,
    ),
  );
});
