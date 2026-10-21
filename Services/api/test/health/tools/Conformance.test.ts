import { readFileSync } from "node:fs";
import { assert, describe, it } from "@effect/vitest";
import { Effect, Layer, Option, Schema, Stream } from "effect";
import { SqlClient } from "effect/sql";
import { TestClock } from "effect/testing";
import type { DeviceId, UserId } from "../../../src/core/Ids.ts";
import { healthBatchKey, ingestHealthBatch } from "../../../src/health/HealthIngestion.ts";
import {
  HealthToolError,
  type HealthToolHandlers,
  HealthToolkit,
  withUnimplementedTools,
} from "../../../src/health/tools/HealthToolkit.ts";
import {
  makeHealthMcpServer,
  RemoteHealthToolkit,
} from "../../../src/health/tools/HealthMcpServer.ts";
import { healthSummary } from "../../../src/health/tools/Summary.ts";
import { appendAgentAccess } from "../../../src/store/AgentAccessLog.ts";
import type { StoreSql } from "../../../src/store/StoreSql.ts";
import { UserStores } from "../../../src/store/UserStores.ts";
import { TestCore } from "../../core/TestCoreDatabase.ts";
import { TestStores, TestUserStores } from "../../store/TestUserStores.ts";
import { postMcp, sessionless, viaStore } from "../../mcp/TestMcp.ts";
import { batchFile, TestHealthIngestion, TestHealthOutbox } from "../TestHealthIngestion.ts";

// The Health toolkit's conformance harness (851-2841). `conformance/dataset.json` is a synthetic
// account and `conformance/cases.json` tool calls on it with the answers both MCP servers must
// give. This side ingests the dataset as the server does (an iPhone's uploads through
// `ingestHealthBatch`) and calls the server's implementation through the toolkit, so arguments
// and outputs go through the tools' schemas. The Mac's `lil-health mcp` (851-2844) runs the same
// cases on the same dataset after a sync. The remote MCP server (851-2851) runs them too, over
// Streamable HTTP, for the tools it serves.

const Iso = Schema.String.annotate({ description: "An ISO 8601 time" });
const millis = (iso: string) => Date.parse(iso);

const Dataset = Schema.Struct({
  batches: Schema.Array(
    Schema.Struct({
      device: Schema.String,
      receivedAt: Iso,
      lines: Schema.Array(Schema.Unknown),
    }),
  ),
});

const Case = Schema.Struct({
  name: Schema.String,
  tool: Schema.String,
  now: Iso,
  pins: Schema.optionalKey(
    Schema.Array(Schema.Struct({ id: Schema.String, position: Schema.Finite })),
  ),
  arguments: Schema.Unknown,
  expected: Schema.optionalKey(Schema.Unknown),
  expectedError: Schema.optionalKey(Schema.Boolean),
});
type Case = typeof Case.Type;

const read = <S extends Schema.Top & { readonly DecodingServices: never }>(
  file: string,
  schema: S,
) =>
  Schema.decodeUnknownSync(schema)(
    JSON.parse(readFileSync(new URL(`conformance/${file}`, import.meta.url), "utf8")),
  );

const dataset = read("dataset.json", Dataset);
const { cases } = read("cases.json", Schema.Struct({ cases: Schema.Array(Case) }));

type ToolName = keyof typeof HealthToolkit.tools;

/**
 * An implementation of some of the tools over a store holding the dataset. Tools it doesn't have
 * yet are skipped, so each tool joins the harness as it's implemented.
 */
const serverImplementation: {
  readonly [Name in ToolName]?: (sql: StoreSql) => HealthToolHandlers[Name];
} = {
  summary: (sql) => (params) => healthSummary(sql, params),
};

// Synthetic data only (AGENTS.md).
const userId = "usr_000000000000000000000000c0" as UserId;

/** `userId` in the core database: ingestion drops batches for users it doesn't know. */
const KnownUser = Layer.effectDiscard(
  Effect.gen(function* () {
    const sql = yield* SqlClient.SqlClient;
    yield* sql`INSERT INTO users (id, display_name, created_at) VALUES (${userId}, NULL, 0)`;
  }),
).pipe(Layer.orDie, Layer.provideMerge(TestCore));

/** A fresh store with the dataset ingested batch by batch, at each batch's time, and `pins`. */
const storeWithDataset = (pins: Case["pins"]) =>
  Effect.gen(function* () {
    const { files } = yield* TestHealthOutbox;
    for (const [index, batch] of dataset.batches.entries()) {
      yield* TestClock.setTime(millis(batch.receivedAt));
      const batchId = `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`;
      files.set(healthBatchKey(userId, batchId), batchFile(batch.lines));
      yield* ingestHealthBatch({ userId, batchId, deviceId: batch.device as DeviceId });
      const status = yield* (yield* UserStores).forUser(userId).healthBatch(batchId);
      assert.deepInclude(status, { status: "applied", rejected: 0 }, `batch ${index + 1}`);
    }
    if (pins !== undefined) {
      // As the Mac writes them (`POST /v1/sync/mutations`).
      yield* (yield* UserStores).forUser(userId).pushMutations(
        "conformance-pins",
        pins.map(({ id, position }) => ({
          entity: "health_pin",
          op: "upsert",
          id,
          row: { position },
        })),
      );
    }
    const sql = (yield* TestStores).sqlFor(userId);
    assert.isDefined(sql);
    return sql!;
  }).pipe(Effect.provide(Layer.mergeAll(TestUserStores, TestHealthIngestion, KnownUser)));

/**
 * Calls a tool as an MCP server would, arguments decoded and the output encoded, giving the
 * encoded output or, for a declared failure (`HealthToolError`), its message.
 */
const callTool = (
  sql: StoreSql,
  name: ToolName,
  args: unknown,
): Effect.Effect<{ readonly isFailure: boolean; readonly output: unknown }> =>
  Effect.gen(function* () {
    const toolkit = yield* HealthToolkit;
    const results = yield* toolkit.handle(name, args as never);
    const result = Option.getOrThrow(yield* Stream.runLast(results));
    return { isFailure: result.isFailure, output: result.encodedResult };
  }).pipe(
    Effect.catch((error) =>
      error instanceof HealthToolError
        ? Effect.succeed({ isFailure: true, output: error.message })
        : Effect.die(error),
    ),
    Effect.provide(
      HealthToolkit.toLayer(
        withUnimplementedTools(
          Object.fromEntries(
            Object.entries(serverImplementation).map(([tool, implement]) => [tool, implement(sql)]),
          ),
        ),
      ),
    ),
  );

/** Whether two JSON values match, numbers within a relative 1e-9. */
const matches = (actual: unknown, expected: unknown): boolean => {
  if (typeof actual === "number" && typeof expected === "number") {
    return Math.abs(actual - expected) <= 1e-9 * Math.max(1, Math.abs(expected));
  }
  if (Array.isArray(actual) && Array.isArray(expected)) {
    return (
      actual.length === expected.length && actual.every((value, i) => matches(value, expected[i]))
    );
  }
  if (
    typeof actual === "object" &&
    actual !== null &&
    typeof expected === "object" &&
    expected !== null &&
    !Array.isArray(actual) &&
    !Array.isArray(expected)
  ) {
    const keys = Object.keys(expected);
    return (
      Object.keys(actual).length === keys.length &&
      keys.every(
        (key) =>
          key in actual &&
          matches(
            (actual as Record<string, unknown>)[key],
            (expected as Record<string, unknown>)[key],
          ),
      )
    );
  }
  return actual === expected;
};

describe("Health toolkit conformance cases", () => {
  it("are well formed: known tools, valid arguments and expected outputs", () => {
    assert.isAbove(cases.length, 0);
    for (const testCase of cases) {
      const tool = HealthToolkit.tools[testCase.tool as ToolName];
      assert.isDefined(tool, `${testCase.name}: unknown tool ${testCase.tool}`);
      assert.isTrue(
        (testCase.expected !== undefined) !== (testCase.expectedError === true),
        `${testCase.name}: give either expected or expectedError`,
      );
      if (testCase.expectedError === true) continue;
      Schema.decodeUnknownSync(tool.parametersSchema as Schema.Codec<unknown>)(testCase.arguments);
      Schema.decodeUnknownSync(tool.successSchema as Schema.Codec<unknown>)(testCase.expected);
    }
  });

  for (const testCase of cases) {
    const tool = testCase.tool as ToolName;
    (serverImplementation[tool] === undefined ? it.effect.skip : it.effect)(
      `the server: ${testCase.name}`,
      () =>
        Effect.gen(function* () {
          const sql = yield* storeWithDataset(testCase.pins);
          yield* TestClock.setTime(millis(testCase.now));
          const result = yield* callTool(sql, tool, testCase.arguments);
          if (testCase.expectedError === true) {
            assert.isTrue(result.isFailure, JSON.stringify(result.output));
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

  for (const testCase of cases) {
    const tool = testCase.tool as ToolName;
    (tool in RemoteHealthToolkit.tools ? it.effect : it.effect.skip)(
      `the remote MCP server: ${testCase.name}`,
      () =>
        Effect.gen(function* () {
          const sql = yield* storeWithDataset(testCase.pins);
          yield* TestClock.setTime(millis(testCase.now));
          const server = yield* makeHealthMcpServer({
            sql,
            record: (access) => Effect.sync(() => appendAgentAccess(sql, access, 0)),
          });
          const request = sessionless("tools/call", { name: tool, arguments: testCase.arguments });
          const response = yield* postMcp(
            viaStore(server),
            "http://store/health",
            request.body,
            request.headers,
          );
          assert.strictEqual(response.status, 200);
          const result = response.message?.["result"] as Record<string, unknown> | undefined;
          assert.isDefined(result, JSON.stringify(response.message));
          if (testCase.expectedError === true) {
            assert.isTrue(result!["isError"], JSON.stringify(result));
            return;
          }
          assert.isFalse(result!["isError"], JSON.stringify(result));
          // The output as structured content, and the same as text.
          const [content] = result!["content"] as Array<{ readonly text: string }>;
          assert.deepStrictEqual(JSON.parse(content!.text), result!["structuredContent"]);
          if (!matches(result!["structuredContent"], testCase.expected)) {
            assert.deepStrictEqual(result!["structuredContent"], testCase.expected);
          }
        }),
    );
  }
});
