import { assert, describe, it } from "@effect/vitest";
import { Effect, Predicate, Schema } from "effect";
import { TestClock } from "effect/testing";
import { canonicalCardSpec } from "../../../src/health/cards/CardSpecValidator.ts";
import type { Json } from "../../../src/health/cards/CardJson.ts";
import { seedWelcomeCards } from "../../../src/health/cards/WelcomeSeed.ts";
import { CardsToolkit } from "../../../src/health/cards/CardsToolkit.ts";
import {
  agentClientHeader,
  agentGrantHeader,
  agentScopesHeader,
} from "../../../src/mcp/AgentHeaders.ts";
import { healthMcpPath } from "../../../src/health/tools/HealthMcpServer.ts";
import { combinedMcpPath } from "../../../src/mcp/CombinedMcpServer.ts";
import { makeStoreMcpServers } from "../../../src/mcp/StoreMcpServers.ts";
import { entities } from "../../../src/store/Registry.ts";
import { UserStores } from "../../../src/store/UserStores.ts";
import { TestStores } from "../../store/TestUserStores.ts";
import { postMcp, sessionless, viaStore } from "../../mcp/TestMcp.ts";
import {
  conformanceUserId,
  matches,
  millis,
  readDataset,
  readJson,
  storeWithBatches,
} from "../HealthConformance.ts";

// The card tools' conformance cases (851-3217, docs/decisions/cards.md › MCP tools): the same
// calls of the seven card tools, on the same synthetic account, must give the same outputs and the
// same errors, word for word, from the remote MCP server and from the Mac's `lil-health mcp`.
// `tool-conformance/cases.json` holds them: the account is the cards' conformance dataset
// (`conformance/dataset.json`), the welcome seed and the file's `cards`, and each case a few calls
// in order, so a write is followed by what it changed. This side ingests the dataset as the
// server ingests uploads, seeds the store as it seeds when it starts (`seedWelcomeCards`), takes
// the file's cards as a Mac pushes them, then calls lil health's MCP server and the combined one
// in the store, as an agent with both card scopes, over Streamable HTTP. The Mac's side
// (`CardToolConformanceTests`) syncs the same into its database and calls `lil-health mcp`, with
// a stand-in for the app answering the writes.

const Iso = Schema.String.check(Schema.makeFilter((iso: string) => !Number.isNaN(millis(iso))));

/** One card the account has besides the welcome seed, as a Mac pushed it. */
const StoredCard = Schema.Struct({
  id: Schema.String,
  /** As a spec input: the Mac and the server canonicalize it before it's stored. */
  spec: Schema.Json,
  position: Schema.String,
  createdAt: Iso,
  updatedAt: Iso,
});

const Call = Schema.Struct({
  tool: Schema.Literals(Object.keys(CardsToolkit.tools) as Array<keyof typeof CardsToolkit.tools>),
  arguments: Schema.Record(Schema.String, Schema.Json),
  expected: Schema.optionalKey(Schema.Json),
  /** The tool's error message, word for word. */
  expectedError: Schema.optionalKey(Schema.String),
});

const Case = Schema.Struct({
  name: Schema.String,
  note: Schema.optionalKey(Schema.String),
  now: Iso,
  calls: Schema.NonEmptyArray(Call),
});

const file = readJson(
  new URL("tool-conformance/cases.json", import.meta.url),
  Schema.Struct({
    seededAt: Iso,
    cards: Schema.Array(StoredCard),
    cases: Schema.Array(Case),
  }),
);
const batches = readDataset(new URL("conformance/dataset.json", import.meta.url));

/** Where a card made in a case goes in its expected outputs and later calls' arguments. */
const newCard = "<new card>";

/** A ULID's first 10 digits: its time, `now` in Unix milliseconds, in Crockford's base 32. */
const ulidTime = (now: number) => {
  const digits = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = "";
  for (let index = 0, rest = now; index < 10; index += 1, rest = Math.floor(rest / 32)) {
    time = digits[rest % 32] + time;
  }
  return time;
};

/** `value` with every `<new card>` replaced by `id`. */
const withNewCard = (value: Json, id: string | undefined): Json => {
  if (value === newCard) {
    assert.isDefined(id, `${newCard} before a card was made`);
    return id!;
  }
  if (Array.isArray(value)) return value.map((item) => withNewCard(item, id));
  if (Predicate.isObject(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, withNewCard(item as Json, id)]),
    );
  }
  return value;
};

/** The ID `actual` has where `expected` says `<new card>`, if any: the first, depth first. */
const newCardIn = (expected: Json, actual: unknown): string | undefined => {
  if (expected === newCard) return typeof actual === "string" ? actual : undefined;
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return undefined;
    for (const [index, item] of expected.entries()) {
      const found = newCardIn(item, actual[index]);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  if (Predicate.isObject(expected) && Predicate.isObject(actual)) {
    for (const [key, item] of Object.entries(expected)) {
      const found = newCardIn(item as Json, (actual as Record<string, unknown>)[key]);
      if (found !== undefined) return found;
    }
  }
  return undefined;
};

/** The welcome seed, then the file's cards, as a Mac pushes them (`POST /v1/sync/mutations`). */
const account = Effect.gen(function* () {
  const sql = (yield* TestStores).sqlFor(conformanceUserId);
  assert.isDefined(sql);
  // As the store seeds when it starts.
  assert.deepStrictEqual(seedWelcomeCards(sql!, entities, millis(file.seededAt)), {
    _tag: "Seeded",
    appended: 6,
  });
  yield* (yield* UserStores).forUser(conformanceUserId).pushMutations(
    "conformance-cards",
    file.cards.map((card) => {
      const canonical = canonicalCardSpec(card.spec);
      assert.isUndefined(canonical.errors, `${card.id}: ${JSON.stringify(canonical.errors)}`);
      return {
        entity: "health_card",
        op: "upsert",
        id: card.id,
        row: {
          spec: canonical.spec!,
          position: card.position,
          createdAt: millis(card.createdAt),
          updatedAt: millis(card.updatedAt),
          seed: null,
        },
      };
    }),
  );
});

/** One of the store's MCP servers: where it is, and its tools' names. */
interface Server {
  readonly label: string;
  readonly path: string;
  readonly name: (tool: string) => string;
}

/**
 * A case's calls, in order, through one of the store's MCP servers, made as the store makes them
 * (`makeStoreMcpServers`: recording calls in its access log and writing with its
 * `applyMutations`), but here, so its calls run on the test's clock.
 */
const runCase = (testCase: typeof Case.Type, server: Server) =>
  Effect.gen(function* () {
    yield* account;
    const stores = yield* TestStores;
    const store = stores.storeFor(conformanceUserId)!;
    const servers = yield* makeStoreMcpServers({
      sql: stores.sqlFor(conformanceUserId)!,
      record: store.recordAgentAccess,
      write: store.applyMutations,
    });
    const handler = servers(server.path);
    assert.isDefined(handler, server.path);
    const send = viaStore(handler!);
    const url = `http://store${server.path}`;
    const { name } = server;
    yield* TestClock.setTime(millis(testCase.now));
    let made: string | undefined;
    for (const [index, call] of testCase.calls.entries()) {
      const label = `call ${index + 1}, ${call.tool}`;
      const request = sessionless("tools/call", {
        name: name(call.tool),
        arguments: withNewCard(call.arguments, made),
      });
      const response = yield* postMcp(send, url, request.body, {
        ...request.headers,
        [agentGrantHeader]: "agr_01jbconformance00000000000",
        [agentClientHeader]: "Conformance",
        [agentScopesHeader]: "health:read health:cards",
      });
      assert.strictEqual(response.status, 200, label);
      const result = response.message?.["result"] as Record<string, unknown> | undefined;
      assert.isDefined(result, `${label}: ${JSON.stringify(response.message)}`);
      const [content] = result!["content"] as Array<{ readonly text: string }>;
      if (call.expectedError !== undefined) {
        assert.isTrue(result!["isError"], `${label}: ${JSON.stringify(result)}`);
        assert.strictEqual(content!.text, call.expectedError, label);
        continue;
      }
      assert.isFalse(result!["isError"], `${label}: ${content?.text}`);
      const output = result!["structuredContent"];
      // The output as structured content, and the same as text.
      assert.deepStrictEqual(JSON.parse(content!.text), output, label);
      const found = made === undefined ? newCardIn(call.expected!, output) : undefined;
      if (found !== undefined) {
        // A new card's ID: a ULID of now.
        assert.match(found, /^card_[0-9A-HJKMNP-TV-Z]{26}$/, label);
        assert.strictEqual(found.slice(5, 15), ulidTime(millis(testCase.now)), label);
        made = found;
      }
      const expected = withNewCard(call.expected!, made);
      if (!matches(output, expected)) {
        // Shows the difference.
        assert.deepStrictEqual(output, expected, label);
      }
    }
  });

describe("card tool conformance cases", () => {
  it("are well formed: unique names, an expected output or error per call", () => {
    assert.isAbove(file.cases.length, 0);
    assert.strictEqual(new Set(file.cases.map(({ name }) => name)).size, file.cases.length);
    for (const testCase of file.cases) {
      for (const call of testCase.calls) {
        assert.isTrue(
          (call.expected === undefined) !== (call.expectedError === undefined),
          `${testCase.name}: give either expected or expectedError`,
        );
        if (call.expected === undefined) continue;
        Schema.decodeUnknownSync(
          CardsToolkit.tools[call.tool].successSchema as Schema.Codec<unknown>,
        )(withNewCard(call.expected, "card_00000000000000000000000000"));
      }
    }
  });

  // lil health's own server, and the combined one (851-2900), where the tools are `health.<tool>`.
  const servers: ReadonlyArray<Server> = [
    { label: "the remote MCP server", path: healthMcpPath, name: (tool) => tool },
    { label: "the combined MCP server", path: combinedMcpPath, name: (tool) => `health.${tool}` },
  ];
  for (const server of servers) {
    for (const testCase of file.cases) {
      it.effect(`${server.label}: ${testCase.name}`, () =>
        storeWithBatches(batches, runCase(testCase, server)).pipe(Effect.asVoid),
      );
    }
  }
});
