import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import type { Mutation } from "../../src/store/Changes.ts";
import { readChanges } from "../../src/store/ChangeLog.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "../store/TestStoreSql.ts";

// Synthetic data only (AGENTS.md).
const provenance = {
  sourceName: "Test Watch",
  sourceBundleId: "com.apple.health.00000000",
  sourceRevision: { version: "11.0", productType: "Watch7,1", operatingSystemVersion: "11.0.0" },
  device: { name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch" },
  metadata: { HKTimeZone: "Europe/Bucharest" },
};

const steps = {
  type: "HKQuantityTypeIdentifierStepCount",
  startDate: 1760400000000,
  endDate: 1760400600000,
  value: 412,
  unit: "count",
  categoryValue: null,
  correlationId: null,
  ...provenance,
};

const records: ReadonlyArray<{
  readonly entity: string;
  readonly id: string;
  readonly row: Record<string, unknown>;
  readonly update: Record<string, unknown>;
}> = [
  {
    entity: "health_sample",
    id: "6f1c2a40-0000-4000-8000-000000000001",
    row: steps,
    update: { value: 415 },
  },
  {
    entity: "health_sample",
    id: "6f1c2a40-0000-4000-8000-000000000002",
    row: {
      ...steps,
      type: "HKCategoryTypeIdentifierSleepAnalysis",
      value: null,
      unit: null,
      categoryValue: 3,
    },
    update: { categoryValue: 4 },
  },
  {
    entity: "health_correlation",
    id: "6f1c2a40-0000-4000-8000-000000000003",
    row: {
      type: "HKCorrelationTypeIdentifierBloodPressure",
      startDate: 1760400000000,
      endDate: 1760400000000,
      ...provenance,
    },
    update: { metadata: null },
  },
  {
    entity: "health_characteristic",
    id: "HKCharacteristicTypeIdentifierDateOfBirth",
    row: { value: { year: 1990, month: 4, day: 2 } },
    update: { value: { year: 1990, month: 4, day: 3 } },
  },
  {
    entity: "health_activity_summary",
    id: "2026-10-14",
    row: {
      activeEnergyBurned: 512.5,
      activeEnergyBurnedGoal: 600,
      appleMoveTime: null,
      appleMoveTimeGoal: null,
      appleExerciseTime: 34,
      appleExerciseTimeGoal: 30,
      appleStandHours: 9,
      appleStandHoursGoal: 12,
      activityMoveMode: "activeEnergy",
      paused: false,
    },
    update: { paused: true },
  },
];

describe("health entities", () => {
  it.effect("insert, update and delete through applyMutations, with every change in the log", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      const upserts = (field: "row" | "update") =>
        records.map((record): Mutation => ({
          entity: record.entity,
          op: "upsert",
          id: record.id,
          row: record[field] as Mutation extends { row: infer R } ? R : never,
        }));

      yield* store.applyMutations(upserts("row"));
      yield* store.applyMutations(upserts("update"));
      yield* store.applyMutations(
        records.map((record): Mutation => ({ entity: record.entity, op: "delete", id: record.id })),
      );

      const page = readChanges(sql, 0, 100);
      if (!("changes" in page)) return assert.fail("compacted");
      const n = records.length;
      assert.strictEqual(page.head, n * 3);
      records.forEach((record, index) => {
        const [inserted, updated, deleted] = [index, n + index, 2 * n + index].map(
          (position) => page.changes[position],
        );
        assert.deepStrictEqual(inserted?.row, { id: record.id, ...record.row }, record.entity);
        assert.deepStrictEqual(
          updated?.row,
          { id: record.id, ...record.row, ...record.update },
          record.entity,
        );
        assert.deepInclude(deleted, { entity: record.entity, id: record.id, op: "delete" });
      });
      for (const table of ["health_sample", "health_correlation", "health_characteristic"]) {
        assert.deepStrictEqual(sql.exec(`SELECT count(*) AS n FROM ${table}`), [{ n: 0 }]);
      }
    }),
  );

  it.effect("the same sample from two iPhones is one record", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      const sample: Mutation = {
        entity: "health_sample",
        op: "upsert",
        id: "6f1c2a40-0000-4000-8000-000000000001",
        row: steps,
      };
      yield* store.applyMutations([sample]);
      assert.deepStrictEqual(yield* store.applyMutations([sample]), { head: 1, appended: 0 });
      assert.deepStrictEqual(sql.exec("SELECT count(*) AS n FROM health_sample"), [{ n: 1 }]);
    }),
  );

  it.effect("rejects samples missing what every sample has", () =>
    Effect.gen(function* () {
      const store = makeUserStore(makeTestStoreSql());
      const { sourceName: _, ...withoutSource } = steps;
      const error = yield* Effect.flip(
        store.applyMutations([
          { entity: "health_sample", op: "upsert", id: "x", row: withoutSource },
        ]),
      );
      assert.include(error.message, "sourceName");
    }),
  );

  it("indexes samples and correlations by type and start", () => {
    const sql = makeTestStoreSql();
    makeUserStore(sql);
    const indexes = sql
      .exec("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'health_%'")
      .map((row) => row["name"]);
    assert.includeMembers(indexes, ["health_sample_type_start", "health_correlation_type_start"]);
    const plan = sql
      .exec(
        "EXPLAIN QUERY PLAN SELECT id FROM health_sample WHERE type = ? AND start_date > ?",
        "HKQuantityTypeIdentifierStepCount",
        0,
      )
      .map((row) => row["detail"] as string);
    assert.isTrue(
      plan.some((detail) => detail.includes("health_sample_type_start")),
      plan.join(),
    );
  });
});
