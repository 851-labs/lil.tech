import { readFileSync } from "node:fs";
import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { eq } from "drizzle-orm";
import { CoreDb } from "../../src/core/CoreDb.ts";
import { agentGrants } from "../../src/core/Schema.ts";
import type { Deployment } from "../../src/Deployment.ts";
import { maxMcpRequestBytes } from "../../src/mcp/McpRoutes.ts";
import { type RateLimitName, RateLimits } from "../../src/RateLimits.ts";
import { TestStores } from "../store/TestUserStores.ts";
import { type Handler, send, withApi } from "../TestApi.ts";
import { type Approval, approve } from "../oauth/TestAgents.ts";
import {
  initialize,
  initialized,
  inSession,
  postMcp,
  sessionless,
  sessionProtocol,
} from "./TestMcp.ts";

// lil health's MCP server through the Worker (851-2851): the token, origin and rate limit checks,
// then the server in the user's store, on both kinds of protocol. Synthetic users only.

const preview: Deployment["Service"] = { environment: "preview", version: "1" };
const previewOrigin = "https://lil-api-pr-12.example.workers.dev";
const previewResource = `${previewOrigin}/health`;
const metadataUrl = `${previewOrigin}/.well-known/oauth-protected-resource/health`;

const form = (handler: Handler, url: string, params: Record<string, string>) =>
  send(
    handler,
    new Request(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params).toString(),
    }),
  ).pipe(Effect.map((response) => response.body as Record<string, string>));

/** Connects Claude Code for a new user, as the authorization page and token endpoint do. */
const connect = (
  handler: Handler,
  options: {
    readonly origin?: string;
    readonly resource?: string;
    readonly approval?: Approval;
  } = {},
) =>
  Effect.gen(function* () {
    const origin = options.origin ?? previewOrigin;
    const approval =
      options.approval ?? (yield* approve({ resource: options.resource ?? previewResource }));
    const tokens = yield* form(handler, `${origin}/oauth/token`, {
      grant_type: "authorization_code",
      code: approval.code,
      client_id: approval.clientId,
      redirect_uri: approval.redirectUri,
      code_verifier: approval.verifier,
      resource: approval.resource,
    });
    assert.isString(tokens["access_token"]);
    return {
      ...approval,
      accessToken: tokens["access_token"]!,
      refreshToken: tokens["refresh_token"]!,
    };
  });

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

/** Calls `/health` with a sessionless request. */
const call = (
  handler: Handler,
  token: string | undefined,
  method: string,
  params: Record<string, unknown> = {},
  headers: Record<string, string> = {},
  url = `${previewOrigin}/health`,
) => {
  const request = sessionless(method, params);
  return postMcp(handler, url, request.body, {
    ...request.headers,
    ...(token === undefined ? {} : bearer(token)),
    ...headers,
  });
};

/** The tools as `mcp-tools.json` has them. */
const committedTools = JSON.parse(
  readFileSync(new URL("../../mcp-tools.json", import.meta.url), "utf8"),
) as Array<Record<string, unknown>>;

const result = (message: Record<string, unknown> | undefined) =>
  message?.["result"] as Record<string, unknown> | undefined;

describe("the Health MCP server", () => {
  it.live("lists and calls tools without a session (2026-07-28)", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const { accessToken } = yield* connect(handler);
          const list = yield* call(handler, accessToken, "tools/list");
          assert.strictEqual(list.status, 200);
          const tools = result(list.message)?.["tools"] as Array<Record<string, unknown>>;
          assert.deepStrictEqual(
            tools.map((tool) => tool["name"]),
            ["summary"],
          );
          // Exactly as `mcp-tools.json` lists it, which the Mac's server lists too: read-only.
          assert.deepStrictEqual(
            tools,
            committedTools.filter((tool) => tool["name"] === "summary"),
          );
          assert.deepInclude(tools[0]?.["annotations"], {
            readOnlyHint: true,
            destructiveHint: false,
            openWorldHint: false,
          });
          const summary = yield* call(handler, accessToken, "tools/call", {
            name: "summary",
            arguments: { timeZone: "Europe/London" },
          });
          assert.strictEqual(summary.status, 200);
          assert.isNull(summary.headers.get("mcp-session-id"));
          assert.deepInclude(result(summary.message), { isError: false });
          assert.deepInclude(result(summary.message)?.["structuredContent"], {
            timeZone: "Europe/London",
            pinned: false,
          });
        }),
      preview,
    ),
  );

  it.live("lists and calls tools in a session (2025-11-25), until it's ended", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const { accessToken } = yield* connect(handler);
          const url = `${previewOrigin}/health`;
          const started = yield* postMcp(handler, url, initialize(), bearer(accessToken));
          assert.strictEqual(started.status, 200);
          assert.deepInclude(result(started.message), { protocolVersion: sessionProtocol });
          const session = started.headers.get("mcp-session-id");
          assert.isString(session);
          const headers = {
            ...bearer(accessToken),
            "mcp-session-id": session!,
            "mcp-protocol-version": sessionProtocol,
          };
          assert.strictEqual((yield* postMcp(handler, url, initialized, headers)).status, 202);
          const list = yield* postMcp(handler, url, inSession("tools/list"), headers);
          assert.deepStrictEqual(
            (result(list.message)?.["tools"] as Array<Record<string, unknown>>).map(
              (tool) => tool["name"],
            ),
            ["summary"],
          );
          const summary = yield* postMcp(
            handler,
            url,
            inSession("tools/call", { name: "summary", arguments: {} }),
            headers,
          );
          assert.deepInclude(result(summary.message), { isError: false });
          assert.deepInclude(result(summary.message)?.["structuredContent"], { timeZone: "UTC" });

          // Ending the session: it's gone, and the client must start a new one.
          assert.strictEqual(
            (yield* postMcp(handler, url, undefined, headers, "DELETE")).status,
            204,
          );
          const ended = yield* postMcp(handler, url, inSession("tools/list"), headers);
          assert.strictEqual(ended.status, 404);
          const unknown = yield* postMcp(handler, url, inSession("tools/list"), {
            ...headers,
            "mcp-session-id": "00000000-0000-4000-8000-000000000000",
          });
          assert.strictEqual(unknown.status, 404);
        }),
      preview,
    ),
  );

  it.live("logs each tool call in the user's store, as the Worker names the agent", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const { accessToken, userId } = yield* connect(handler);
          const [grant] = yield* (yield* CoreDb)
            .select()
            .from(agentGrants)
            .where(eq(agentGrants.userId, userId))
            .pipe(Effect.orDie);
          // A client can't pass for another grant or agent.
          const forged = {
            "x-lil-agent-grant": "agr_forged",
            "x-lil-agent-client": "Someone%20else",
          };
          yield* call(handler, accessToken, "tools/list", {}, forged);
          yield* call(
            handler,
            accessToken,
            "tools/call",
            { name: "summary", arguments: {} },
            forged,
          );
          const failed = yield* call(handler, accessToken, "tools/call", {
            name: "summary",
            arguments: { timeZone: "Mars/Olympus_Mons" },
          });
          assert.deepInclude(result(failed.message), { isError: true });
          const sql = (yield* TestStores).sqlFor(userId)!;
          const rows = sql.exec(
            `SELECT grant_id, client_name, tool, types, range, date, outcome, rows
              FROM agent_access_log ORDER BY id`,
          );
          const logged = {
            grant_id: grant!.id,
            client_name: "Claude Code",
            tool: "summary",
            types: null,
            range: null,
            date: null,
          };
          // Only tool calls: listing tools reads nothing.
          assert.deepStrictEqual(rows, [
            { ...logged, outcome: "ok", rows: 6 },
            { ...logged, outcome: "error", rows: 0 },
          ]);
        }),
      preview,
    ),
  );

  it.live("answers 401 with where to sign in, without a token or with a bad one", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const missing = yield* call(handler, undefined, "tools/list");
          assert.strictEqual(missing.status, 401);
          assert.strictEqual(
            missing.headers.get("www-authenticate"),
            `Bearer resource_metadata="${metadataUrl}", scope="health:read"`,
          );
          for (const authorization of ["Bearer lma_unknown", "Basic dXNlcjpwYXNz", "Bearer"]) {
            const refused = yield* call(handler, undefined, "tools/list", {}, { authorization });
            assert.strictEqual(refused.status, 401, authorization);
          }
          const invalid = yield* call(handler, "lma_unknown", "tools/list");
          assert.strictEqual(
            invalid.headers.get("www-authenticate"),
            `Bearer resource_metadata="${metadataUrl}", scope="health:read", ` +
              `error="invalid_token", error_description="The access token is invalid or revoked"`,
          );
          assert.deepStrictEqual(invalid.message, {
            error: "invalid_token",
            error_description: "The access token is invalid or revoked",
          });
          // Never from the query string.
          const { accessToken } = yield* connect(handler);
          const query = yield* call(
            handler,
            undefined,
            "tools/list",
            {},
            {},
            `${previewOrigin}/health?access_token=${accessToken}`,
          );
          assert.strictEqual(query.status, 401);
        }),
      preview,
    ),
  );

  it.live("refuses the apps' own tokens and other apps' agent tokens", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const signedIn = yield* send(
            handler,
            new Request(`${previewOrigin}/v1/auth/dev`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ displayName: "Dev" }),
            }),
          );
          const { accessToken: appToken } = signedIn.body as { accessToken: string };
          const app = yield* call(handler, appToken, "tools/list");
          assert.strictEqual(app.status, 401);
          assert.include(app.headers.get("www-authenticate"), 'error="invalid_token"');

          const mail = yield* connect(handler, { resource: `${previewOrigin}/mail` });
          const other = yield* call(handler, mail.accessToken, "tools/list");
          assert.strictEqual(other.status, 401);
        }),
      preview,
    ),
  );

  it.live("cuts a revoked grant off at its next request", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const agent = yield* connect(handler);
          assert.strictEqual((yield* call(handler, agent.accessToken, "tools/list")).status, 200);
          yield* form(handler, `${previewOrigin}/oauth/revoke`, {
            token: agent.refreshToken,
            client_id: agent.clientId,
          });
          const revoked = yield* call(handler, agent.accessToken, "tools/list");
          assert.strictEqual(revoked.status, 401);
          assert.include(revoked.headers.get("www-authenticate"), 'error="invalid_token"');
        }),
      preview,
    ),
  );

  it.live("refuses requests from browsers, and anything but POST and DELETE", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const { accessToken } = yield* connect(handler);
          for (const token of [accessToken, undefined]) {
            const browser = yield* call(
              handler,
              token,
              "tools/list",
              {},
              { origin: "https://evil.example" },
            );
            assert.strictEqual(browser.status, 403);
            assert.isNull(browser.headers.get("access-control-allow-origin"));
          }
          for (const method of ["GET", "PUT", "OPTIONS"]) {
            const response = yield* postMcp(
              handler,
              `${previewOrigin}/health`,
              undefined,
              bearer(accessToken),
              method,
            );
            assert.strictEqual(response.status, 405, method);
            assert.strictEqual(response.headers.get("allow"), "POST, DELETE", method);
          }
        }),
      preview,
    ),
  );

  it.live("refuses large requests, and has no subscriptions to hold open", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const { accessToken } = yield* connect(handler);
          const large = yield* call(handler, accessToken, "tools/call", {
            name: "summary",
            arguments: { timeZone: "x".repeat(maxMcpRequestBytes) },
          });
          assert.strictEqual(large.status, 413);
          const listen = yield* call(handler, accessToken, "subscriptions/listen", {
            notifications: { toolsListChanged: true },
          });
          assert.deepInclude(listen.message?.["error"], { code: -32601 });
        }),
      preview,
    ),
  );

  it.live("limits each grant to its own budget", () => {
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
      agentToken: counter("agentToken", Infinity),
      agent: counter("agent", 2),
    });
    return withApi(
      (handler) =>
        Effect.gen(function* () {
          const first = yield* connect(handler);
          const second = yield* connect(handler);
          for (let i = 0; i < 2; i++) {
            assert.strictEqual((yield* call(handler, first.accessToken, "tools/list")).status, 200);
          }
          const limited = yield* call(handler, first.accessToken, "tools/list");
          assert.strictEqual(limited.status, 429);
          assert.strictEqual(limited.headers.get("retry-after"), "60");
          // Bad tokens cost nobody's budget, and other grants keep theirs.
          assert.strictEqual((yield* call(handler, "lma_unknown", "tools/list")).status, 401);
          assert.strictEqual((yield* call(handler, second.accessToken, "tools/list")).status, 200);
        }),
      preview,
      limits,
    );
  });

  it.live("is on the MCP host in staging, and nowhere in prod yet", () =>
    Effect.gen(function* () {
      yield* withApi(
        (handler) =>
          Effect.gen(function* () {
            const resource = "https://mcp.staging.lil.tech/health";
            const agent = yield* connect(handler, {
              origin: "https://api.staging.lil.tech",
              resource,
            });
            const list = yield* call(handler, agent.accessToken, "tools/list", {}, {}, resource);
            assert.strictEqual(list.status, 200);
            const missing = yield* call(handler, undefined, "tools/list", {}, {}, resource);
            assert.include(
              missing.headers.get("www-authenticate"),
              'resource_metadata="https://mcp.staging.lil.tech/.well-known/oauth-protected-resource/health"',
            );
            const onApi = yield* call(
              handler,
              agent.accessToken,
              "tools/list",
              {},
              {},
              "https://api.staging.lil.tech/health",
            );
            assert.strictEqual(onApi.status, 404);
          }),
        { environment: "staging", version: "1" },
      );
      yield* withApi(
        (handler) =>
          Effect.gen(function* () {
            const response = yield* call(
              handler,
              undefined,
              "tools/list",
              {},
              {},
              "https://mcp.lil.tech/health",
            );
            assert.strictEqual(response.status, 404);
          }),
        { environment: "prod", version: "1" },
      );
    }),
  );
});
