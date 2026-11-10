import { assert, describe, it } from "@effect/vitest";
import { Effect, Option, Schema, Stream } from "effect";
import { AiError } from "effect/ai";
import { TestClock } from "effect/testing";
import { HealthToolError, HealthToolkit } from "../../../src/health/tools/HealthToolkit.ts";
import {
  healthMcpApp,
  makeHealthMcpServer,
  makeTurns,
} from "../../../src/health/tools/HealthMcpServer.ts";
import { storeHealthTools } from "../../../src/health/tools/StoreHealthTools.ts";
import { agentScopesHeader } from "../../../src/mcp/AgentHeaders.ts";
import { makeCombinedMcpServer } from "../../../src/mcp/CombinedMcpServer.ts";
import { agentResources } from "../../../src/oauth/Hosts.ts";
import { type AgentAccess, appendAgentAccess } from "../../../src/store/AgentAccessLog.ts";
import type { StoreSql } from "../../../src/store/StoreSql.ts";
import { UserStores } from "../../../src/store/UserStores.ts";
import { storeMcpSessions } from "../../../src/store/McpSessions.ts";
import { postMcp, sessionless, viaStore } from "../../mcp/TestMcp.ts";
import {
  conformanceUserId,
  matches,
  millis,
  readBlobs,
  readDataset,
  readJson,
  storeWithBatches,
} from "../HealthConformance.ts";

// The Health toolkit's conformance harness (851-2841). `conformance/dataset.json` is a synthetic
// account and `conformance/cases.json` tool calls on it with the answers both MCP servers must
// give. This side ingests the dataset as the server does (an iPhone's uploads through
// `ingestHealthBatch`) and calls the server's implementation through the toolkit, so arguments
// and outputs go through the tools' schemas. The Mac's `lil-health mcp` (851-2844) runs the same
// cases on the same dataset after a sync. The remote MCP server (851-2851) and the combined one
// (851-2900) run them too, over Streamable HTTP. A case that fails gives the tool's error message,
// which every side must answer word for word, arguments outside the input schema included
// (851-4034).

const Case = Schema.Struct({
  name: Schema.String,
  tool: Schema.String,
  now: Schema.String,
  pins: Schema.optionalKey(
    Schema.Array(Schema.Struct({ id: Schema.String, position: Schema.Finite })),
  ),
  arguments: Schema.Unknown,
  expected: Schema.optionalKey(Schema.Unknown),
  /** The tool's error message, word for word. */
  expectedError: Schema.optionalKey(Schema.String),
});
type Case = typeof Case.Type;

const batches = readDataset(new URL("conformance/dataset.json", import.meta.url));
const blobs = readBlobs(new URL("conformance/blobs.json", import.meta.url));
const { cases } = readJson(
  new URL("conformance/cases.json", import.meta.url),
  Schema.Struct({ cases: Schema.Array(Case) }),
);

type ToolName = keyof typeof HealthToolkit.tools;

/** A fresh store with the dataset ingested batch by batch, at each batch's time, and `pins`. */
const storeWithDataset = (pins: Case["pins"]) =>
  storeWithBatches(
    batches,
    pins === undefined
      ? Effect.void
      : Effect.gen(function* () {
          // As a Mac from before pins were retired (851-2990) writes them
          // (`POST /v1/sync/mutations`).
          yield* (yield* UserStores).forUser(conformanceUserId).pushMutations(
            "conformance-pins",
            pins.map(({ id, position }) => ({
              entity: "health_pin",
              op: "upsert",
              id,
              row: { position },
            })),
          );
        }),
  );

/**
 * Calls a tool as an MCP server would, arguments decoded and the output encoded, giving the
 * encoded output or, for a declared failure (`HealthToolError`) or arguments outside the input
 * schema, its message, as the server's tool error has it.
 */
const callTool = (
  sql: StoreSql,
  name: ToolName,
  args: unknown,
): Effect.Effect<{ readonly isFailure: boolean; readonly output: unknown }> =>
  Effect.gen(function* () {
    const toolkit = yield* HealthToolkit;
    // Every issue with the arguments, as the MCP server decodes them.
    const results = yield* toolkit.handle(name, args as never, undefined, { errors: "all" });
    const result = Option.getOrThrow(yield* Stream.runLast(results));
    return { isFailure: result.isFailure, output: result.encodedResult };
  }).pipe(
    Effect.catch((error) =>
      error instanceof HealthToolError
        ? Effect.succeed({ isFailure: true, output: error.message })
        : AiError.isAiError(error) && error.reason._tag === "ToolParameterValidationError"
          ? Effect.succeed({ isFailure: true, output: error.reason.message })
          : Effect.die(error),
    ),
    Effect.provide(HealthToolkit.toLayer(storeHealthTools(sql, blobs))),
  );

describe("Health toolkit conformance cases", () => {
  it("are well formed: known tools, valid arguments and expected outputs", () => {
    assert.isAbove(cases.length, 0);
    for (const testCase of cases) {
      const tool = HealthToolkit.tools[testCase.tool as ToolName];
      assert.isDefined(tool, `${testCase.name}: unknown tool ${testCase.tool}`);
      assert.isTrue(
        (testCase.expected !== undefined) !== (testCase.expectedError !== undefined),
        `${testCase.name}: give either expected or expectedError`,
      );
      if (testCase.expectedError !== undefined) continue;
      Schema.decodeUnknownSync(tool.parametersSchema as Schema.Codec<unknown>)(testCase.arguments);
      Schema.decodeUnknownSync(tool.successSchema as Schema.Codec<unknown>)(testCase.expected);
    }
  });

  for (const testCase of cases) {
    const tool = testCase.tool as ToolName;
    it.effect(`the server: ${testCase.name}`, () =>
      Effect.gen(function* () {
        const sql = yield* storeWithDataset(testCase.pins);
        yield* TestClock.setTime(millis(testCase.now));
        const result = yield* callTool(sql, tool, testCase.arguments);
        if (testCase.expectedError !== undefined) {
          assert.isTrue(result.isFailure, JSON.stringify(result.output));
          assert.strictEqual(result.output, testCase.expectedError);
          return;
        }
        assert.isFalse(result.isFailure, JSON.stringify(result.output));
        if (!matches(result.output, testCase.expected)) {
          // Shows the difference.
          assert.deepStrictEqual(result.output, testCase.expected);
        }
      }),
    );
  }

  // Over Streamable HTTP: lil health's own server, and the combined one (851-2900), where the
  // tools are `health.<tool>`.
  const servers = [
    {
      label: "the remote MCP server",
      url: "http://store/health",
      name: (tool: string) => tool,
      make: (sql: StoreSql, record: (access: AgentAccess) => Effect.Effect<void>) =>
        makeHealthMcpServer({ sql, record, blobs }),
    },
    {
      label: "the combined MCP server",
      url: "http://store/",
      name: (tool: string) => `health.${tool}`,
      make: (sql: StoreSql, record: (access: AgentAccess) => Effect.Effect<void>) =>
        Effect.flatMap(makeTurns(), (turns) =>
          makeCombinedMcpServer({
            registry: agentResources,
            apps: { health: healthMcpApp({ sql, record, turns, blobs }) },
            sessions: storeMcpSessions(sql),
          }),
        ),
    },
  ];
  for (const server of servers) {
    for (const testCase of cases) {
      it.effect(`${server.label}: ${testCase.name}`, () =>
        Effect.gen(function* () {
          const sql = yield* storeWithDataset(testCase.pins);
          yield* TestClock.setTime(millis(testCase.now));
          const handler = yield* server.make(sql, (access) =>
            Effect.sync(() => appendAgentAccess(sql, access, 0)),
          );
          const request = sessionless("tools/call", {
            name: server.name(testCase.tool),
            arguments: testCase.arguments,
          });
          const response = yield* postMcp(viaStore(handler), server.url, request.body, {
            ...request.headers,
            [agentScopesHeader]: "health:read",
          });
          assert.strictEqual(response.status, 200);
          const result = response.message?.["result"] as Record<string, unknown> | undefined;
          assert.isDefined(result, JSON.stringify(response.message));
          const [content] = result!["content"] as Array<{ readonly text: string }>;
          if (testCase.expectedError !== undefined) {
            assert.isTrue(result!["isError"], JSON.stringify(result));
            assert.strictEqual(content!.text, testCase.expectedError);
            return;
          }
          assert.isFalse(result!["isError"], JSON.stringify(result));
          // The output as structured content, and the same as text.
          assert.deepStrictEqual(JSON.parse(content!.text), result!["structuredContent"]);
          if (!matches(result!["structuredContent"], testCase.expected)) {
            assert.deepStrictEqual(result!["structuredContent"], testCase.expected);
          }
        }),
      );
    }
  }
});
