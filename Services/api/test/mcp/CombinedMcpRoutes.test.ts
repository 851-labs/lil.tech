import { readFileSync } from "node:fs";
import { assert, describe, it } from "@effect/vitest";
import { Effect, type Layer } from "effect";
import { eq } from "drizzle-orm";
import { type ConsentType, Consents } from "../../src/core/Consents.ts";
import { CoreDb } from "../../src/core/CoreDb.ts";
import { agentGrants } from "../../src/core/Schema.ts";
import type { Deployment } from "../../src/Deployment.ts";
import { maxMcpRequestBytes } from "../../src/mcp/McpRoutes.ts";
import { type RateLimitName, RateLimits } from "../../src/RateLimits.ts";
import { TestStores } from "../store/TestUserStores.ts";
import { type Handler, send, withApi } from "../TestApi.ts";
import { approve, WithMail } from "../oauth/TestAgents.ts";
import {
  initialize,
  initialized,
  inSession,
  type McpResponse,
  postMcp,
  sessionless,
  sessionProtocol,
} from "./TestMcp.ts";

// The combined MCP server through the Worker (851-2900): `POST /` on the MCP host, with every
// app's tools as `<app>.<tool>`. Synthetic users only.

const preview: Deployment["Service"] = { environment: "preview", version: "1" };
const previewOrigin = "https://lil-api-pr-12.example.workers.dev";
const rootUrl = `${previewOrigin}/`;
const metadataUrl = `${previewOrigin}/.well-known/oauth-protected-resource`;

const form = (handler: Handler, url: string, params: Record<string, string>) =>
  send(
    handler,
    new Request(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params).toString(),
    }),
  ).pipe(Effect.map((response) => response.body as Record<string, string>));

/**
 * Connects Claude Code for a new user to `resource` (the combined server), as the authorization
 * page and token endpoint do, with `consents` given as Allow gives them.
 */
const connect = (
  handler: Handler,
  options: {
    readonly origin?: string;
    readonly resource?: string;
    readonly scopes?: ReadonlyArray<string>;
    readonly consents?: ReadonlyArray<ConsentType>;
  } = {},
) =>
  Effect.gen(function* () {
    const origin = options.origin ?? previewOrigin;
    const approval = yield* approve({
      resource: options.resource ?? previewOrigin,
      ...(options.scopes === undefined ? {} : { scopes: options.scopes }),
    });
    for (const type of options.consents ?? ["agents:health"]) {
      // Any version: what counts is that it's in force.
      yield* (yield* Consents).grant(approval.userId, type, "2026-10-21").pipe(Effect.orDie);
    }
    const tokens = yield* form(handler, `${origin}/oauth/token`, {
      grant_type: "authorization_code",
      code: approval.code,
      client_id: approval.clientId,
      redirect_uri: approval.redirectUri,
      code_verifier: approval.verifier,
      resource: approval.resource,
    });
    assert.isString(tokens["access_token"], JSON.stringify(tokens));
    return {
      ...approval,
      accessToken: tokens["access_token"]!,
      refreshToken: tokens["refresh_token"]!,
    };
  });

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

/** Calls the combined server with a sessionless request. */
const call = (
  handler: Handler,
  token: string | undefined,
  method: string,
  params: Record<string, unknown> = {},
  headers: Record<string, string> = {},
  url = rootUrl,
) => {
  const request = sessionless(method, params);
  return postMcp(handler, url, request.body, {
    ...request.headers,
    ...(token === undefined ? {} : bearer(token)),
    ...headers,
  });
};

/** lil health's tools as `mcp-tools.json` has them, under their names on the combined server. */
const healthTools = (
  JSON.parse(readFileSync(new URL("../../mcp-tools.json", import.meta.url), "utf8")) as Array<
    Record<string, unknown>
  >
).map((tool) => ({ ...tool, name: `health.${String(tool["name"])}` }));

const result = (message: Record<string, unknown> | undefined) =>
  message?.["result"] as Record<string, unknown> | undefined;

const toolNames = (response: McpResponse) =>
  (result(response.message)!["tools"] as Array<{ readonly name: string }>).map((tool) => tool.name);

const withPreview = <A, E>(
  use: Parameters<typeof withApi<A, E>>[0],
  overrides?: Layer.Layer<never>,
) => withApi(use, preview, RateLimits.unlimited, overrides);

describe("the combined MCP server", () => {
  it.live("lists and calls lil health's tools as health.*, without a session (2026-07-28)", () =>
    withPreview((handler) =>
      Effect.gen(function* () {
        const { accessToken } = yield* connect(handler);
        const list = yield* call(handler, accessToken, "tools/list");
        assert.strictEqual(list.status, 200);
        assert.deepStrictEqual(result(list.message)?.["tools"], healthTools);
        const summary = yield* call(handler, accessToken, "tools/call", {
          name: "health.summary",
          arguments: { timeZone: "Europe/London" },
        });
        assert.strictEqual(summary.status, 200);
        assert.isNull(summary.headers.get("mcp-session-id"));
        assert.deepInclude(result(summary.message), { isError: false });
        assert.deepInclude(result(summary.message)?.["structuredContent"], {
          timeZone: "Europe/London",
        });
        // Only by its name here.
        const bare = yield* call(handler, accessToken, "tools/call", {
          name: "summary",
          arguments: {},
        });
        assert.deepInclude(bare.message?.["error"], { code: -32602 });
      }),
    ),
  );

  it.live("lists and calls tools in a session (2025-11-25), until it's ended", () =>
    withPreview((handler) =>
      Effect.gen(function* () {
        const { accessToken } = yield* connect(handler);
        const started = yield* postMcp(handler, rootUrl, initialize(), bearer(accessToken));
        assert.strictEqual(started.status, 200);
        assert.deepInclude(result(started.message), { protocolVersion: sessionProtocol });
        assert.deepInclude(result(started.message)?.["serverInfo"], { name: "lil" });
        const session = started.headers.get("mcp-session-id");
        assert.isString(session);
        const headers = {
          ...bearer(accessToken),
          "mcp-session-id": session!,
          "mcp-protocol-version": sessionProtocol,
        };
        assert.strictEqual((yield* postMcp(handler, rootUrl, initialized, headers)).status, 202);
        const list = yield* postMcp(handler, rootUrl, inSession("tools/list"), headers);
        assert.deepStrictEqual(result(list.message)?.["tools"], healthTools);
        const metric = yield* postMcp(
          handler,
          rootUrl,
          inSession("tools/call", { name: "health.list_types", arguments: {} }),
          headers,
        );
        assert.deepInclude(result(metric.message), { isError: false });
        // A session is the combined server's own: lil health's server doesn't know it.
        const elsewhere = yield* postMcp(
          handler,
          `${previewOrigin}/health`,
          inSession("tools/list"),
          headers,
        );
        assert.strictEqual(elsewhere.status, 401);
        assert.strictEqual(
          (yield* postMcp(handler, rootUrl, undefined, headers, "DELETE")).status,
          204,
        );
        const ended = yield* postMcp(handler, rootUrl, inSession("tools/list"), headers);
        assert.strictEqual(ended.status, 404);
      }),
    ),
  );

  it.live("logs each call as lil health's server does, and records the first read", () =>
    withPreview((handler) =>
      Effect.gen(function* () {
        const { accessToken, userId } = yield* connect(handler);
        const grantOf = Effect.gen(function* () {
          const [grant] = yield* (yield* CoreDb)
            .select()
            .from(agentGrants)
            .where(eq(agentGrants.userId, userId))
            .pipe(Effect.orDie);
          return grant!;
        });
        yield* call(handler, accessToken, "tools/list");
        assert.isNull((yield* grantOf).firstUsedAt);
        // A client can't pass for another grant, or widen its scopes.
        const forged = {
          "x-lil-agent-grant": "agr_forged",
          "x-lil-agent-scopes": "health:read mail:read",
        };
        yield* call(handler, accessToken, "tools/call", { name: "health.summary" }, forged);
        yield* call(handler, accessToken, "tools/call", {
          name: "health.metric",
          arguments: { type: "steps", range: "W" },
        });
        const grant = yield* grantOf;
        assert.isNumber(grant.firstUsedAt);
        const sql = (yield* TestStores).sqlFor(userId)!;
        assert.deepStrictEqual(
          sql.exec(`SELECT grant_id, client_name, tool, outcome FROM agent_access_log ORDER BY id`),
          [
            { grant_id: grant.id, client_name: "Claude Code", tool: "summary", outcome: "ok" },
            { grant_id: grant.id, client_name: "Claude Code", tool: "metric", outcome: "ok" },
          ],
        );
      }),
    ),
  );

  it.live("answers 401 naming the root metadata and every app's scope", () =>
    Effect.gen(function* () {
      for (const [overrides, scope] of [
        [undefined, "health:read"],
        [WithMail, "health:read mail:read"],
      ] as const) {
        yield* withPreview(
          (handler) =>
            Effect.gen(function* () {
              const missing = yield* call(handler, undefined, "tools/list");
              assert.strictEqual(missing.status, 401);
              assert.strictEqual(
                missing.headers.get("www-authenticate"),
                `Bearer resource_metadata="${metadataUrl}", scope="${scope}"`,
              );
              const invalid = yield* call(handler, "lma_unknown", "tools/list");
              assert.strictEqual(
                invalid.headers.get("www-authenticate"),
                `Bearer resource_metadata="${metadataUrl}", scope="${scope}", ` +
                  `error="invalid_token", error_description="The access token is invalid or revoked"`,
              );
            }),
          overrides,
        );
      }
    }),
  );

  it.live("refuses lil health's own tokens, and its tokens there", () =>
    withPreview((handler) =>
      Effect.gen(function* () {
        const health = yield* connect(handler, { resource: `${previewOrigin}/health` });
        const own = yield* call(handler, health.accessToken, "tools/list");
        assert.strictEqual(own.status, 401);
        assert.include(own.headers.get("www-authenticate"), 'error="invalid_token"');
        const combined = yield* connect(handler);
        const there = yield* call(
          handler,
          combined.accessToken,
          "tools/list",
          {},
          {},
          `${previewOrigin}/health`,
        );
        assert.strictEqual(there.status, 401);
      }),
    ),
  );

  it.live("refuses browsers, other methods and large requests", () =>
    withPreview((handler) =>
      Effect.gen(function* () {
        const { accessToken } = yield* connect(handler);
        const browser = yield* call(
          handler,
          accessToken,
          "tools/list",
          {},
          { origin: "https://evil.example" },
        );
        assert.strictEqual(browser.status, 403);
        for (const method of ["GET", "PUT"]) {
          const response = yield* postMcp(handler, rootUrl, undefined, bearer(accessToken), method);
          assert.strictEqual(response.status, 405, method);
          assert.strictEqual(response.headers.get("allow"), "POST, DELETE", method);
        }
        const large = yield* call(handler, accessToken, "tools/call", {
          name: "health.summary",
          arguments: { timeZone: "x".repeat(maxMcpRequestBytes) },
        });
        assert.strictEqual(large.status, 413);
      }),
    ),
  );

  it.live("cuts an app off once its agents consent is withdrawn, and a revoked grant", () =>
    withPreview((handler) =>
      Effect.gen(function* () {
        const agent = yield* connect(handler);
        assert.strictEqual((yield* call(handler, agent.accessToken, "tools/list")).status, 200);
        yield* (yield* Consents).withdraw(agent.userId, "agents:health").pipe(Effect.orDie);
        const withdrawn = yield* call(handler, agent.accessToken, "tools/call", {
          name: "health.summary",
          arguments: {},
        });
        assert.strictEqual(withdrawn.status, 403);
        assert.include(withdrawn.headers.get("www-authenticate"), 'error="insufficient_scope"');
        assert.include(withdrawn.headers.get("www-authenticate"), `scope="health:read"`);
        // Connecting an agent again gives consent again, but not to this grant, made before.
        yield* Effect.sleep("5 millis");
        yield* (yield* Consents)
          .grant(agent.userId, "agents:health", "2026-10-21")
          .pipe(Effect.orDie);
        const regranted = yield* call(handler, agent.accessToken, "tools/list");
        assert.strictEqual(regranted.status, 403);

        const other = yield* connect(handler);
        yield* form(handler, `${previewOrigin}/oauth/revoke`, {
          token: other.refreshToken,
          client_id: other.clientId,
        });
        const revoked = yield* call(handler, other.accessToken, "tools/list");
        assert.strictEqual(revoked.status, 401);
      }),
    ),
  );

  it.live("serves the apps the grant's scopes cover, while their consents stand", () =>
    withPreview(
      (handler) =>
        Effect.gen(function* () {
          const both = yield* connect(handler, {
            scopes: ["health:read", "mail:read"],
            consents: ["agents:health", "agents:mail" as ConsentType],
          });
          const list = yield* call(handler, both.accessToken, "tools/list");
          assert.deepStrictEqual(toolNames(list), [
            ...healthTools.map((tool) => tool.name),
            "mail.summary",
            "mail.search",
          ]);
          const mail = yield* call(handler, both.accessToken, "tools/call", {
            name: "mail.summary",
            arguments: {},
          });
          assert.deepStrictEqual(result(mail.message)?.["structuredContent"], {
            app: "mail",
            unread: 3,
          });
          // lil mail's agents turned off: its tools are gone from the connection.
          yield* (yield* Consents)
            .withdraw(both.userId, "agents:mail" as ConsentType)
            .pipe(Effect.orDie);
          const narrowed = yield* call(handler, both.accessToken, "tools/list");
          assert.deepStrictEqual(
            toolNames(narrowed),
            healthTools.map((tool) => tool.name),
          );
          const refused = yield* call(handler, both.accessToken, "tools/call", {
            name: "mail.summary",
            arguments: {},
          });
          assert.deepInclude(refused.message?.["error"], { code: -32602 });

          // A grant for lil mail alone lists only its tools.
          const mailOnly = yield* connect(handler, {
            scopes: ["mail:read"],
            consents: ["agents:mail" as ConsentType],
          });
          const mailList = yield* call(handler, mailOnly.accessToken, "tools/list");
          assert.deepStrictEqual(toolNames(mailList), ["mail.summary", "mail.search"]);
          const toHealth = yield* call(handler, mailOnly.accessToken, "tools/call", {
            name: "health.summary",
            arguments: {},
          });
          assert.deepInclude(toHealth.message?.["error"], { code: -32602 });
        }),
      WithMail,
    ),
  );

  it.live("counts every app's calls against the grant's one budget", () => {
    let count = 0;
    const counter = (limit: RateLimitName) => () =>
      Effect.sync(() => (limit === "agent" ? ++count <= 2 : true));
    const limits = RateLimits.make({
      signIn: counter("signIn"),
      user: counter("user"),
      refresh: counter("refresh"),
      clientRegistration: counter("clientRegistration"),
      agentToken: counter("agentToken"),
      agent: counter("agent"),
    });
    return withApi(
      (handler) =>
        Effect.gen(function* () {
          const { accessToken } = yield* connect(handler);
          for (let i = 0; i < 2; i++) {
            assert.strictEqual((yield* call(handler, accessToken, "tools/list")).status, 200);
          }
          assert.strictEqual((yield* call(handler, accessToken, "tools/list")).status, 429);
        }),
      preview,
      limits,
    );
  });

  it.live("is on the MCP host in staging, not the API's, and not in prod yet", () =>
    Effect.gen(function* () {
      yield* withApi(
        (handler) =>
          Effect.gen(function* () {
            const resource = "https://mcp.staging.lil.tech";
            const agent = yield* connect(handler, {
              origin: "https://api.staging.lil.tech",
              resource,
            });
            const list = yield* call(
              handler,
              agent.accessToken,
              "tools/list",
              {},
              {},
              `${resource}/`,
            );
            assert.strictEqual(list.status, 200);
            const missing = yield* call(handler, undefined, "tools/list", {}, {}, `${resource}/`);
            assert.include(
              missing.headers.get("www-authenticate"),
              'resource_metadata="https://mcp.staging.lil.tech/.well-known/oauth-protected-resource"',
            );
            const onApi = yield* call(
              handler,
              agent.accessToken,
              "tools/list",
              {},
              {},
              "https://api.staging.lil.tech/",
            );
            assert.strictEqual(onApi.status, 404);
          }),
        { environment: "staging", version: "1" },
      );
      yield* withApi(
        (handler) =>
          Effect.gen(function* () {
            for (const url of ["https://mcp.lil.tech/", "https://api.lil.tech/"]) {
              const missing = yield* call(handler, undefined, "tools/list", {}, {}, url);
              assert.strictEqual(missing.status, 404, url);
            }
            // lil health's own server is unchanged.
            const health = yield* call(
              handler,
              undefined,
              "tools/list",
              {},
              {},
              "https://mcp.lil.tech/health",
            );
            assert.strictEqual(health.status, 401);
          }),
        { environment: "prod", version: "1" },
      );
    }),
  );
});
