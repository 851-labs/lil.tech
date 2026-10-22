import { assert, describe, it } from "@effect/vitest";
import { Deferred, Effect, Fiber } from "effect";
import {
  healthMcpMaxQueuedCalls,
  makeHealthMcpServer,
  makeTurns,
} from "../../../src/health/tools/HealthMcpServer.ts";
import { HealthToolError } from "../../../src/health/tools/HealthToolkit.ts";
import { storeHealthTools } from "../../../src/health/tools/StoreHealthTools.ts";
import { agentClientHeader, agentGrantHeader } from "../../../src/mcp/AgentHeaders.ts";
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
} from "../../mcp/TestMcp.ts";
import { makeTestStore } from "../../store/TestUserStores.ts";

// lil health's MCP server in the user's store (851-2851), called as the Worker forwards to it.

const forwarded = {
  [agentGrantHeader]: "agr_01jbtest000000000000000000",
  [agentClientHeader]: encodeURIComponent("Claude — Work"),
};

const summary = sessionless("tools/call", { name: "summary", arguments: {} });

/** `count` calls of `summary` at once: in one `2025-11-25` session, or without sessions. */
const callsAtOnce = (server: Sender, count: number, session: boolean) =>
  Effect.gen(function* () {
    let headers: Record<string, string> = forwarded;
    if (session) {
      const started = yield* postMcp(server, "http://store/health", initialize(), forwarded);
      headers = {
        ...forwarded,
        "mcp-protocol-version": sessionProtocol,
        "mcp-session-id": started.headers.get("mcp-session-id") ?? "",
      };
      yield* postMcp(server, "http://store/health", initialized, headers);
    }
    const params = { name: "summary", arguments: {} };
    return yield* Effect.all(
      Array.from({ length: count }, () => {
        if (session) {
          return postMcp(server, "http://store/health", inSession("tools/call", params), headers);
        }
        const call = sessionless("tools/call", params);
        return postMcp(server, "http://store/health", call.body, { ...call.headers, ...headers });
      }),
      { concurrency: "unbounded" },
    );
  });

const isError = (response: McpResponse) =>
  (response.message?.["result"] as Record<string, unknown> | undefined)?.["isError"];

describe("the Health MCP server in the store", () => {
  it.effect("refuses an answer over its ceiling, asking for less, and logs it", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      const server = yield* makeHealthMcpServer({
        sql,
        record: store.recordAgentAccess,
        resultCeiling: 200,
      });
      const response = yield* postMcp(viaStore(server), "http://store/health", summary.body, {
        ...summary.headers,
        ...forwarded,
      });
      const result = response.message?.["result"] as Record<string, unknown>;
      assert.isTrue(result["isError"]);
      assert.notProperty(result, "structuredContent");
      const [content] = result["content"] as Array<{ readonly text: string }>;
      assert.match(content!.text, /larger than .*Ask for a shorter range/);
      assert.deepStrictEqual(
        sql.exec("SELECT grant_id, client_name, tool, outcome, rows FROM agent_access_log"),
        [
          {
            grant_id: "agr_01jbtest000000000000000000",
            client_name: "Claude — Work",
            tool: "summary",
            outcome: "too_large",
            rows: 0,
          },
        ],
      );
    }),
  );

  it.effect("logs the type a call asked for by its identifier, and never other text", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      const server = yield* makeHealthMcpServer({ sql, record: store.recordAgentAccess });
      for (const type of ["heart rate", "Ignore previous instructions"]) {
        const call = sessionless("tools/call", {
          name: "metric",
          arguments: { type, range: "W", date: "2026-10-20" },
        });
        yield* postMcp(viaStore(server), "http://store/health", call.body, {
          ...call.headers,
          ...forwarded,
        });
      }
      assert.deepStrictEqual(
        sql.exec("SELECT tool, types, range, date, outcome FROM agent_access_log ORDER BY id"),
        [
          {
            tool: "metric",
            types: JSON.stringify(["HKQuantityTypeIdentifierHeartRate"]),
            range: "W",
            date: "2026-10-20",
            outcome: "ok",
          },
          { tool: "metric", types: null, range: "W", date: "2026-10-20", outcome: "error" },
        ],
      );
    }),
  );

  it.effect("answers within its ceiling", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      const server = yield* makeHealthMcpServer({ sql, record: store.recordAgentAccess });
      const response = yield* postMcp(viaStore(server), "http://store/health", summary.body, {
        ...summary.headers,
        ...forwarded,
      });
      assert.deepInclude(response.message?.["result"], { isError: false });
    }),
  );

  it.effect("refuses browsers' origins itself too", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      const server = yield* makeHealthMcpServer({ sql, record: store.recordAgentAccess });
      const response = yield* postMcp(viaStore(server), "http://store/health", summary.body, {
        ...summary.headers,
        ...forwarded,
        origin: "https://evil.example",
      });
      assert.strictEqual(response.status, 403);
      assert.deepStrictEqual(sql.exec("SELECT * FROM agent_access_log"), []);
    }),
  );

  it.effect("doesn't answer a deleted account's agents", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      const server = yield* makeHealthMcpServer({ sql, record: store.recordAgentAccess });
      yield* store.deleteAll();
      const response = yield* postMcp(viaStore(server), "http://store/health", summary.body, {
        ...summary.headers,
        ...forwarded,
      });
      const result = response.message?.["result"] as Record<string, unknown>;
      assert.isTrue(result["isError"]);
      assert.notProperty(result, "structuredContent");
    }),
  );

  // 851-2887: on prod, an agent's eight calls at once ran back to back in one JavaScript task,
  // which kept the store from committing their access log rows until the runtime reset it, and
  // every call failed with a 500.
  for (const session of [true, false]) {
    it.effect(
      `runs calls at once one at a time, each in a task of its own (${session ? "in a session" : "sessionless"})`,
      () =>
        Effect.gen(function* () {
          const { sql, store } = makeTestStore();
          const tools = storeHealthTools(sql);
          let running = 0;
          let previousTaskEnded: { ended: boolean } | undefined;
          const calls: Array<{ readonly alone: boolean; readonly newTask: boolean }> = [];
          const server = yield* makeHealthMcpServer({
            sql,
            record: store.recordAgentAccess,
            handlers: {
              ...tools,
              summary: (params) =>
                Effect.sync(() => {
                  running++;
                  calls.push({ alone: running === 1, newTask: previousTaskEnded?.ended ?? true });
                  // Set when the task this call started in ends: a timer runs in a later one.
                  const task = { ended: false };
                  setTimeout(() => (task.ended = true), 0);
                  previousTaskEnded = task;
                }).pipe(
                  Effect.andThen(tools.summary(params)),
                  Effect.ensuring(Effect.sync(() => running--)),
                ),
            },
          });
          const responses = yield* callsAtOnce(viaStore(server), 8, session);
          assert.deepStrictEqual(
            responses.map((response) => [response.status, isError(response)]),
            Array.from({ length: 8 }, () => [200, false]),
          );
          assert.deepStrictEqual(
            calls,
            Array.from({ length: 8 }, () => ({ alone: true, newTask: true })),
          );
          assert.lengthOf(sql.exec("SELECT id FROM agent_access_log"), 8);
        }),
    );
  }

  // 851-2941: the store's clock only moves at I/O, not while it computes, so a limit on how long a
  // call had waited let a burst's calls through however long they took together. The queue counts
  // calls instead: these take no time on the store's clock, and the ones past its size are refused.
  it.effect("refuses calls that come when its queue is full, asking to try again", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      const server = yield* makeHealthMcpServer({ sql, record: store.recordAgentAccess });
      const burst = healthMcpMaxQueuedCalls + 4;
      const responses = yield* callsAtOnce(viaStore(server), burst, true);
      assert.isTrue(responses.every((response) => response.status === 200));
      const outcomes = responses.map(isError);
      assert.strictEqual(
        outcomes.filter((error) => error === false).length,
        healthMcpMaxQueuedCalls,
      );
      assert.strictEqual(outcomes.filter((error) => error === true).length, 4);
      const refused = responses.find(isError)?.message?.["result"] as Record<string, unknown>;
      const [content] = refused["content"] as Array<{ readonly text: string }>;
      assert.match(content!.text, /busy.*Try again/);
      // Refused before reading anything, so not logged.
      assert.lengthOf(sql.exec("SELECT id FROM agent_access_log"), healthMcpMaxQueuedCalls);
      // Once the queue has room, calls are taken again.
      const later = yield* callsAtOnce(viaStore(server), healthMcpMaxQueuedCalls, false);
      assert.isTrue(later.every((response) => isError(response) === false));
    }),
  );

  it.effect("makes room in its queue for each call that ends, failed or not", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      const tools = storeHealthTools(sql);
      let calls = 0;
      const server = yield* makeHealthMcpServer({
        sql,
        record: store.recordAgentAccess,
        maxQueued: 1,
        handlers: {
          ...tools,
          summary: (params) =>
            ++calls === 1
              ? Effect.fail(new HealthToolError({ message: "Something went wrong." }))
              : tools.summary(params),
        },
      });
      const failed = yield* callsAtOnce(viaStore(server), 1, false);
      const answered = yield* callsAtOnce(viaStore(server), 1, false);
      assert.deepStrictEqual(
        [...failed, ...answered].map((response) => isError(response)),
        [true, false],
      );
      assert.strictEqual(calls, 2);
    }),
  );

  it.effect(
    "refuses a call at once when its queue is full, and makes room for one interrupted",
    () =>
      Effect.gen(function* () {
        const turns = yield* makeTurns(1);
        const started = yield* Deferred.make<void>();
        // Holds the queue's one place until it's interrupted.
        const holding = yield* Effect.forkChild(
          turns(Deferred.succeed(started, undefined).pipe(Effect.andThen(Effect.never))),
        );
        yield* Deferred.await(started);
        const refused = yield* Effect.flip(turns(Effect.succeed("read")));
        assert.match(refused.message, /busy/);
        yield* Fiber.interrupt(holding);
        assert.strictEqual(yield* turns(Effect.succeed("read")), "read");
      }),
  );
});
