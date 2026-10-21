import { assert, describe, it } from "@effect/vitest";
import { Effect, Option } from "effect";
import { Auth } from "../../src/auth/Auth.ts";
import { Consents } from "../../src/core/Consents.ts";
import { CoreDb } from "../../src/core/CoreDb.ts";
import { agentTokens } from "../../src/core/Schema.ts";
import { Devices } from "../../src/core/Devices.ts";
import type { UserId } from "../../src/core/Ids.ts";
import { Users } from "../../src/core/Users.ts";
import type { Deployment } from "../../src/Deployment.ts";
import { agentAccessLogPageSize } from "../../src/oauth/AgentsApi.ts";
import { type AgentAccess, appendAgentAccess } from "../../src/store/AgentAccessLog.ts";
import { UserStores } from "../../src/store/UserStores.ts";
import { postMcp, sessionless } from "../mcp/TestMcp.ts";
import { TestStores } from "../store/TestUserStores.ts";
import { type Handler, send, withApi } from "../TestApi.ts";
import { approve } from "./TestAgents.ts";

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

/** Connects Claude Code for `userId`, as allowing it on the consent page and the token endpoint do. */
const connect = (handler: Handler, userId: UserId, resource = healthResource) =>
  Effect.gen(function* () {
    const approval = yield* approve({ userId, resource });
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

/** A tool call at lil health's MCP server. */
const callSummary = (handler: Handler, accessToken: string) => {
  const request = sessionless("tools/call", { name: "summary", arguments: {} });
  return postMcp(handler, healthResource, request.body, {
    ...request.headers,
    ...bearer(accessToken),
  });
};

interface AgentBody {
  readonly id: string;
  readonly name: string | null;
  readonly app: string | null;
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
          assert.deepStrictEqual(agent, {
            id: agent!.id,
            name: "Claude Code",
            domain: "claude.ai",
            redirectHost: "localhost",
            resource: healthResource,
            app: "health",
            connectedAt,
            lastUsedAt,
          } as AgentBody);
        }),
      preview,
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
