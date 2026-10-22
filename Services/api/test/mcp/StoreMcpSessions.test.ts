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
import { serveStoreMcp, type StoreMcpSessions } from "../../src/mcp/StoreMcpServer.ts";
import {
  findMcpSession,
  mcpSessionPolicy,
  saveMcpSession,
  storeMcpSessions,
} from "../../src/store/McpSessions.ts";
import { registryWithMail } from "../oauth/TestAgents.ts";
import { makeTestStore } from "../store/TestUserStores.ts";
import { testMailApp } from "./TestMailApp.ts";
import {
  initialize,
  initialized,
  inSession,
  type McpResponse,
  postMcp,
  type Sender,
  sessionless,
  viaStore,
} from "./TestMcp.ts";

// Agents' MCP sessions kept in the user's store (851-2947), so they outlive its object: Workers
// takes an idle store out of memory after about 10 seconds, and a new object builds new servers
// over the same SQLite. Synthetic data only.

const forwarded = (scopes = "health:read") => ({
  [agentGrantHeader]: "agr_01jbtest000000000000000000",
  [agentClientHeader]: encodeURIComponent("MCP Inspector"),
  [agentScopesHeader]: scopes,
});

const healthUrl = "http://store/health";
const combinedUrl = "http://store/";

const result = (response: McpResponse) =>
  response.message?.["result"] as Record<string, unknown> | undefined;

type TestStore = ReturnType<typeof makeTestStore>;

/** lil health's own server in `store`, as each new object of the store builds it. */
const healthServer = ({ sql, store }: TestStore) =>
  Effect.map(makeHealthMcpServer({ sql, record: store.recordAgentAccess }), viaStore);

/** The combined server in `store`, with lil health and lil mail, as each new object builds it. */
const combinedServer = ({ sql, store }: TestStore) =>
  Effect.gen(function* () {
    const turns = yield* makeTurns();
    return viaStore(
      yield* makeCombinedMcpServer({
        registry: registryWithMail,
        apps: {
          health: healthMcpApp({ sql, record: store.recordAgentAccess, turns }),
          mail: testMailApp,
        },
        sessions: storeMcpSessions(sql),
      }),
    );
  });

/** Starts a session at `url`, as an agent does: `initialize`, then `notifications/initialized`. */
const startSession = (send: Sender, url: string, protocolVersion: string, scopes?: string) =>
  Effect.gen(function* () {
    const started = yield* postMcp(send, url, initialize(protocolVersion), forwarded(scopes));
    assert.strictEqual(started.status, 200);
    const session = started.headers.get("mcp-session-id");
    assert.isString(session);
    const headers = {
      ...forwarded(scopes),
      "mcp-session-id": session!,
      "mcp-protocol-version": protocolVersion,
    };
    assert.strictEqual((yield* postMcp(send, url, initialized, headers)).status, 202);
    return { session: session!, headers };
  });

const summaryCall = (name = "summary") => inSession("tools/call", { name, arguments: {} });

describe("MCP sessions kept in the store", () => {
  for (const protocolVersion of ["2025-11-25", "2025-06-18"]) {
    it.effect(`go on at a new object's server (${protocolVersion})`, () =>
      Effect.gen(function* () {
        const testStore = makeTestStore();
        const before = yield* healthServer(testStore);
        const { session, headers } = yield* startSession(before, healthUrl, protocolVersion);
        assert.strictEqual((yield* postMcp(before, healthUrl, summaryCall(), headers)).status, 200);

        // The object was taken out of memory: its next one builds the server again.
        const after = yield* healthServer(testStore);
        const call = yield* postMcp(after, healthUrl, summaryCall(), headers);
        assert.strictEqual(call.status, 200);
        assert.deepInclude(result(call)?.["structuredContent"], { timeZone: "UTC" });
        // The agent's session ID stays the one it knows.
        const id = call.headers.get("mcp-session-id");
        assert.isTrue(id === null || id === session);
        const list = yield* postMcp(after, healthUrl, inSession("tools/list"), headers);
        assert.strictEqual(list.status, 200);
        assert.lengthOf(result(list)?.["tools"] as Array<unknown>, 10);
        // And again, at the object after that.
        const third = yield* healthServer(testStore);
        assert.strictEqual((yield* postMcp(third, healthUrl, summaryCall(), headers)).status, 200);
      }),
    );
  }

  it.effect("start a session again once, however many of its requests come at once", () =>
    Effect.gen(function* () {
      const { sql } = makeTestStore();
      const kept = storeMcpSessions(sql)("health");
      let finds = 0;
      const counting: StoreMcpSessions = {
        ...kept,
        find: (id) => Effect.suspend(() => (finds++, kept.find(id))),
      };
      const serve = () =>
        Effect.map(
          serveStoreMcp({
            name: "lil health",
            instructions: "",
            path: "/health",
            register: Effect.void,
            sessions: counting,
          }),
          viaStore,
        );
      const { headers } = yield* startSession(yield* serve(), healthUrl, "2025-11-25");
      const after = yield* serve();
      const responses = yield* Effect.all(
        Array.from({ length: 5 }, () => postMcp(after, healthUrl, inSession("ping"), headers)),
        { concurrency: "unbounded" },
      );
      assert.deepStrictEqual(
        responses.map((response) => response.status),
        [200, 200, 200, 200, 200],
      );
      assert.strictEqual(finds, 1);
    }),
  );

  it.effect("go on at the combined server for the same apps, and not for others", () =>
    Effect.gen(function* () {
      const testStore = makeTestStore();
      const both = "health:read mail:read";
      const { headers } = yield* startSession(
        yield* combinedServer(testStore),
        combinedUrl,
        "2025-11-25",
        both,
      );
      const after = yield* combinedServer(testStore);
      const call = yield* postMcp(after, combinedUrl, summaryCall("health.summary"), headers);
      assert.strictEqual(call.status, 200);
      const list = yield* postMcp(after, combinedUrl, inSession("tools/list"), headers);
      assert.lengthOf(result(list)?.["tools"] as Array<unknown>, 12);
      // Without lil mail, it's another server's session: the agent starts a new one.
      const narrowed = yield* postMcp(
        yield* combinedServer(testStore),
        combinedUrl,
        inSession("tools/list"),
        {
          ...headers,
          ...forwarded("health:read"),
        },
      );
      assert.strictEqual(narrowed.status, 404);
      // And lil health's own server has no such session.
      const own = yield* postMcp(
        yield* healthServer(testStore),
        healthUrl,
        inSession("tools/list"),
        {
          ...headers,
          ...forwarded(),
        },
      );
      assert.strictEqual(own.status, 404);
    }),
  );

  it.effect("end when the agent ends them, in memory or not", () =>
    Effect.gen(function* () {
      const testStore = makeTestStore();
      for (const evictedFirst of [false, true]) {
        const before = yield* healthServer(testStore);
        const { headers } = yield* startSession(before, healthUrl, "2025-11-25");
        const ending = evictedFirst ? yield* healthServer(testStore) : before;
        const ended = yield* postMcp(ending, healthUrl, undefined, headers, "DELETE");
        assert.strictEqual(ended.status, 204);
        assert.strictEqual(
          (yield* postMcp(ending, healthUrl, inSession("tools/list"), headers)).status,
          404,
        );
        const later = yield* healthServer(testStore);
        assert.strictEqual(
          (yield* postMcp(later, healthUrl, inSession("tools/list"), headers)).status,
          404,
        );
        assert.strictEqual(
          (yield* postMcp(later, healthUrl, undefined, headers, "DELETE")).status,
          404,
        );
      }
      assert.deepStrictEqual(testStore.sql.exec("SELECT id FROM mcp_sessions"), []);
    }),
  );

  it.effect("don't start a session that was never kept", () =>
    Effect.gen(function* () {
      const response = yield* postMcp(
        yield* healthServer(makeTestStore()),
        healthUrl,
        inSession("tools/list"),
        {
          ...forwarded(),
          "mcp-session-id": "00000000-0000-4000-8000-000000000000",
          "mcp-protocol-version": "2025-11-25",
        },
      );
      assert.strictEqual(response.status, 404);
    }),
  );

  it.effect("keep nothing for requests without a session (2026-07-28)", () =>
    Effect.gen(function* () {
      const testStore = makeTestStore();
      const call = sessionless("tools/call", { name: "summary", arguments: {} });
      const response = yield* postMcp(yield* healthServer(testStore), healthUrl, call.body, {
        ...call.headers,
        ...forwarded(),
      });
      assert.strictEqual(response.status, 200);
      assert.deepStrictEqual(testStore.sql.exec("SELECT id FROM mcp_sessions"), []);
    }),
  );

  it("keep what the agent sent to start them, for 30 days after their last use", () => {
    const { sql } = makeTestStore();
    const initialize = JSON.stringify({ protocolVersion: "2025-11-25", capabilities: {} });
    saveMcpSession(sql, { id: "a", server: "health", initialize }, 1000);
    assert.strictEqual(findMcpSession(sql, "a", "health", 1000), initialize);
    assert.isUndefined(findMcpSession(sql, "a", "combined:health", 1000));
    const expiry = 1000 + mcpSessionPolicy.retention;
    assert.strictEqual(findMcpSession(sql, "a", "health", expiry), initialize);
    assert.isUndefined(findMcpSession(sql, "a", "health", expiry + 1));
    // Saving another trims expired sessions.
    saveMcpSession(sql, { id: "b", server: "health", initialize }, expiry + 1);
    assert.deepStrictEqual(sql.exec("SELECT id FROM mcp_sessions"), [{ id: "b" }]);
  });

  it("keep at most the most recently used, past which the least recently used goes", () => {
    const { sql } = makeTestStore();
    const policy = { ...mcpSessionPolicy, maxSessions: 2 };
    for (const [index, id] of ["a", "b", "c"].entries()) {
      saveMcpSession(sql, { id, server: "health", initialize: "{}" }, 1000 + index, policy);
    }
    assert.deepStrictEqual(sql.exec("SELECT id FROM mcp_sessions ORDER BY id"), [
      { id: "b" },
      { id: "c" },
    ]);
  });

  it.effect("aren't kept once the account is deleted", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      yield* store.deleteAll();
      saveMcpSession(sql, { id: "a", server: "health", initialize: "{}" }, 1000);
      assert.deepStrictEqual(sql.exec("SELECT id FROM mcp_sessions"), []);
    }),
  );
});
