import { readFileSync } from "node:fs";
import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import {
  healthMcpApp,
  makeHealthMcpServer,
  makeTurns,
} from "../../src/health/tools/HealthMcpServer.ts";
import {
  agentClientHeader,
  agentGrantHeader,
  agentScopesHeader,
} from "../../src/mcp/AgentHeaders.ts";
import { makeCombinedMcpServer } from "../../src/mcp/CombinedMcpServer.ts";
import { agentResources } from "../../src/oauth/Hosts.ts";
import { makeTestStore } from "../store/TestUserStores.ts";
import { registryWithMail } from "../oauth/TestAgents.ts";
import { testMailApp } from "./TestMailApp.ts";
import {
  initialize,
  initialized,
  inSession,
  type McpResponse,
  postMcp,
  type Sender,
  sessionless,
  sessionProtocol,
  viaStore,
} from "./TestMcp.ts";

// The combined MCP server in the user's store (851-2900), with lil health and a fake lil mail,
// called as the Worker forwards to it. Synthetic data only.

const url = "http://store/";

const forwarded = (scopes: string) => ({
  [agentGrantHeader]: "agr_01jbtest000000000000000000",
  [agentClientHeader]: encodeURIComponent("Claude"),
  [agentScopesHeader]: scopes,
});

/** The tools as `mcp-tools.json` has them: lil health's, under their own names. */
const committedTools = JSON.parse(
  readFileSync(new URL("../../mcp-tools.json", import.meta.url), "utf8"),
) as Array<Record<string, unknown>>;

const result = (response: McpResponse) =>
  response.message?.["result"] as Record<string, unknown> | undefined;

const toolNames = (response: McpResponse) =>
  (result(response)!["tools"] as Array<{ readonly name: string }>).map((tool) => tool.name);

/** A store with lil health and lil mail on the combined server. */
const makeServer = Effect.gen(function* () {
  const { sql, store } = makeTestStore();
  const turns = yield* makeTurns();
  const server = yield* makeCombinedMcpServer({
    registry: registryWithMail,
    apps: {
      health: healthMcpApp({ sql, record: store.recordAgentAccess, turns }),
      mail: testMailApp,
    },
  });
  return { sql, send: viaStore(server) };
});

/** A sessionless request to the combined server, with `scopes` forwarded. */
const call = (
  send: Sender,
  scopes: string,
  method: string,
  params: Record<string, unknown> = {},
) => {
  const request = sessionless(method, params);
  return postMcp(send, url, request.body, { ...request.headers, ...forwarded(scopes) });
};

describe("the combined MCP server in the store", () => {
  it.effect("lists every app's tools under its name, with their schemas unchanged", () =>
    Effect.gen(function* () {
      const { send } = yield* makeServer;
      const list = yield* call(send, "health:read mail:read", "tools/list");
      assert.strictEqual(list.status, 200);
      const tools = result(list)?.["tools"] as Array<Record<string, unknown>>;
      const health = tools.filter((tool) => String(tool["name"]).startsWith("health."));
      // lil health's ten, exactly as its own server lists them, but for their names.
      assert.deepStrictEqual(
        health,
        committedTools.map((tool) => ({ ...tool, name: `health.${String(tool["name"])}` })),
      );
      assert.deepStrictEqual(
        tools.filter((tool) => !health.includes(tool)).map((tool) => tool["name"]),
        ["mail.summary", "mail.search"],
      );
      // Both apps have a `summary`, and neither hides the other.
      assert.strictEqual(new Set(tools.map((tool) => tool["name"])).size, tools.length);
    }),
  );

  it.effect("sends each call to its own app's tool", () =>
    Effect.gen(function* () {
      const { send, sql } = yield* makeServer;
      const scopes = "health:read mail:read";
      const health = yield* call(send, scopes, "tools/call", {
        name: "health.summary",
        arguments: { timeZone: "Europe/London" },
      });
      assert.deepInclude(result(health), { isError: false });
      assert.deepInclude(result(health)?.["structuredContent"], { timeZone: "Europe/London" });
      const mail = yield* call(send, scopes, "tools/call", { name: "mail.summary", arguments: {} });
      assert.deepStrictEqual(result(mail)?.["structuredContent"], { app: "mail", unread: 3 });
      const search = yield* call(send, scopes, "tools/call", {
        name: "mail.search",
        arguments: { query: "dinner" },
      });
      assert.deepStrictEqual(result(search)?.["structuredContent"], {
        app: "mail",
        matches: ["Re: dinner"],
      });
      // Names without an app, or with an unknown one, are unknown tools.
      for (const name of ["summary", "calendar.summary", "health.", "health.mail.summary"]) {
        const unknown = yield* call(send, scopes, "tools/call", { name, arguments: {} });
        assert.deepInclude(unknown.message?.["error"], { code: -32602 }, name);
      }
      // lil health's call is in its log under the tool's own name, as from its own server.
      assert.deepStrictEqual(
        sql.exec("SELECT grant_id, client_name, tool, outcome FROM agent_access_log"),
        [
          {
            grant_id: "agr_01jbtest000000000000000000",
            client_name: "Claude",
            tool: "summary",
            outcome: "ok",
          },
        ],
      );
    }),
  );

  it.effect("serves only the apps whose scopes the request carries", () =>
    Effect.gen(function* () {
      const { send } = yield* makeServer;
      const healthOnly = yield* call(send, "health:read", "tools/list");
      assert.deepStrictEqual(
        toolNames(healthOnly),
        committedTools.map((tool) => `health.${String(tool["name"])}`),
      );
      const mailOnly = yield* call(send, "mail:read", "tools/list");
      assert.deepStrictEqual(toolNames(mailOnly), ["mail.summary", "mail.search"]);
      // Another app's tool is an unknown tool.
      const toMail = yield* call(send, "health:read", "tools/call", {
        name: "mail.summary",
        arguments: {},
      });
      assert.deepInclude(toMail.message?.["error"], { code: -32602 });
      const toHealth = yield* call(send, "mail:read", "tools/call", {
        name: "health.summary",
        arguments: {},
      });
      assert.deepInclude(toHealth.message?.["error"], { code: -32602 });
      // Unknown scopes choose nothing, and no app at all is refused.
      for (const scopes of ["", "calendar:read", "health:write"]) {
        assert.strictEqual((yield* call(send, scopes, "tools/list")).status, 403, scopes);
      }
    }),
  );

  it.effect("names itself lil, and says how tools are named, then each app's instructions", () =>
    Effect.gen(function* () {
      const { send } = yield* makeServer;
      const started = yield* postMcp(send, url, initialize(), forwarded("health:read mail:read"));
      assert.deepInclude(result(started)?.["serverInfo"], { name: "lil" });
      const instructions = String(result(started)?.["instructions"]);
      assert.include(instructions, "named <app>.<tool>");
      assert.include(instructions, "## lil health\n\nRead-only access to the user's lil health");
      assert.include(instructions, "## lil mail\n\nRead-only access to the user's lil mail.");
      const healthOnly = yield* postMcp(send, url, initialize(), forwarded("health:read"));
      assert.notInclude(String(result(healthOnly)?.["instructions"]), "lil mail");
    }),
  );

  it.effect("keeps a session with its apps, which ends if they change (2025-11-25)", () =>
    Effect.gen(function* () {
      const { send } = yield* makeServer;
      const started = yield* postMcp(send, url, initialize(), forwarded("health:read mail:read"));
      assert.deepInclude(result(started), { protocolVersion: sessionProtocol });
      const session = started.headers.get("mcp-session-id");
      assert.isString(session);
      const headers = (scopes: string) => ({
        ...forwarded(scopes),
        "mcp-session-id": session!,
        "mcp-protocol-version": sessionProtocol,
      });
      const both = headers("health:read mail:read");
      assert.strictEqual((yield* postMcp(send, url, initialized, both)).status, 202);
      const list = yield* postMcp(send, url, inSession("tools/list"), both);
      assert.lengthOf(toolNames(list), 12);
      const summary = yield* postMcp(
        send,
        url,
        inSession("tools/call", { name: "health.summary", arguments: {} }),
        both,
      );
      assert.deepInclude(result(summary)?.["structuredContent"], { timeZone: "UTC" });
      // Without lil mail (its agents turned off), the session is another server's: it starts again.
      const narrowed = yield* postMcp(send, url, inSession("tools/list"), headers("health:read"));
      assert.strictEqual(narrowed.status, 404);
    }),
  );

  it.effect("shares the store's one queue of calls with lil health's own server", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      // A queue of one: a call that comes while another is in it is refused.
      const turns = yield* makeTurns(1);
      const record = store.recordAgentAccess;
      const own = viaStore(yield* makeHealthMcpServer({ sql, record, turns }));
      const combined = viaStore(
        yield* makeCombinedMcpServer({
          registry: agentResources,
          apps: { health: healthMcpApp({ sql, record, turns }) },
        }),
      );
      const ownCall = sessionless("tools/call", { name: "summary", arguments: {} });
      const combinedCall = sessionless("tools/call", { name: "health.summary", arguments: {} });
      const headers = forwarded("health:read");
      const responses = yield* Effect.all(
        [
          postMcp(own, "http://store/health", ownCall.body, { ...ownCall.headers, ...headers }),
          postMcp(combined, url, combinedCall.body, { ...combinedCall.headers, ...headers }),
        ],
        { concurrency: "unbounded" },
      );
      // The second was refused while the first was in the queue, though it came to the other server.
      assert.deepStrictEqual(
        responses.map((response) => result(response)?.["isError"]),
        [false, true],
      );
      const [content] = result(responses[1]!)!["content"] as Array<{ readonly text: string }>;
      assert.match(content!.text, /busy.*Try again/);
    }),
  );
});
