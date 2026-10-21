import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import {
  type AgentAccess,
  agentAccessLogPolicy,
  appendAgentAccess,
  nextAgentAccessTrimAt,
} from "../../src/store/AgentAccessLog.ts";
import { AccountDeleted } from "../../src/store/Changes.ts";
import { makeTestStore } from "./TestUserStores.ts";

// The agents' access log in the user's store (851-2851). Synthetic grants only.

const day = 24 * 60 * 60 * 1000;

const access = (overrides: Partial<AgentAccess> = {}): AgentAccess => ({
  grantId: "agr_01jbtest000000000000000000",
  clientName: "Claude Code",
  tool: "metric",
  types: ["HKQuantityTypeIdentifierStepCount"],
  range: "W",
  date: "2026-10-20",
  outcome: "ok",
  rows: 7,
  ...overrides,
});

const loggedAt = (sql: ReturnType<typeof makeTestStore>["sql"]) =>
  sql.exec("SELECT at FROM agent_access_log ORDER BY id").map((row) => row["at"]);

describe("the agents' access log", () => {
  it("keeps what was asked for and how it went, never values", () => {
    const { sql } = makeTestStore();
    appendAgentAccess(sql, access(), 1000);
    appendAgentAccess(sql, access({ tool: "summary", types: null, range: null, date: null }), 2000);
    assert.deepStrictEqual(sql.exec("SELECT * FROM agent_access_log ORDER BY id"), [
      {
        id: 1,
        at: 1000,
        grant_id: "agr_01jbtest000000000000000000",
        client_name: "Claude Code",
        tool: "metric",
        types: '["HKQuantityTypeIdentifierStepCount"]',
        range: "W",
        date: "2026-10-20",
        outcome: "ok",
        rows: 7,
      },
      {
        id: 2,
        at: 2000,
        grant_id: "agr_01jbtest000000000000000000",
        client_name: "Claude Code",
        tool: "summary",
        types: null,
        range: null,
        date: null,
        outcome: "ok",
        rows: 7,
      },
    ]);
  });

  it("keeps at most its newest rows", () => {
    const { sql } = makeTestStore();
    const policy = { ...agentAccessLogPolicy, maxRows: 3 };
    for (let at = 1; at <= 5; at++) appendAgentAccess(sql, access(), at, policy);
    assert.deepStrictEqual(loggedAt(sql), [3, 4, 5]);
  });

  it.effect("is trimmed by the alarm once its oldest row is 90 days old", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      assert.isNull(nextAgentAccessTrimAt(sql));
      const start = 1_760_000_000_000;
      yield* TestClock.setTime(start);
      yield* store.recordAgentAccess(access());
      const trimAt = start + agentAccessLogPolicy.retention + agentAccessLogPolicy.trimSlack;
      assert.strictEqual(nextAgentAccessTrimAt(sql), trimAt);
      // Logging is what wakes the store to trim it.
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), trimAt);
      yield* TestClock.setTime(start + 50 * day);
      yield* store.recordAgentAccess(access());
      yield* TestClock.setTime(trimAt);
      yield* store.alarm();
      assert.deepStrictEqual(loggedAt(sql), [start + 50 * day]);
      assert.strictEqual(
        yield* Effect.promise(() => sql.getAlarm()),
        start + 50 * day + agentAccessLogPolicy.retention + agentAccessLogPolicy.trimSlack,
      );
    }),
  );

  it.effect("isn't written once the account is deleted", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      yield* store.deleteAll();
      const error = yield* Effect.flip(store.recordAgentAccess(access()));
      assert.instanceOf(error, AccountDeleted);
      assert.deepStrictEqual(loggedAt(sql), []);
    }),
  );
});
