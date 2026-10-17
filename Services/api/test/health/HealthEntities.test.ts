import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import type { Mutation } from "../../src/store/Changes.ts";
import { readChanges } from "../../src/store/ChangeLog.ts";
import { entities } from "../../src/store/Registry.ts";
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
    // Updates of samples include their key fields.
    update: { type: steps.type, startDate: steps.startDate, value: 415 },
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
    update: {
      type: "HKCategoryTypeIdentifierSleepAnalysis",
      startDate: steps.startDate,
      categoryValue: 4,
    },
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
  {
    entity: "health_statistic",
    id: "dev_000000000000000000000000ph/HKQuantityTypeIdentifierDietaryVitaminB12@1760400000000",
    row: {
      device: "dev_000000000000000000000000ph",
      type: "HKQuantityTypeIdentifierDietaryVitaminB12",
      bucketStart: 1760400000000,
      sum: 2.4,
      unit: "mcg",
    },
    update: { sum: 2.6 },
  },
  {
    entity: "health_statistics_device",
    id: "dev_000000000000000000000000ph",
    row: {
      device: "dev_000000000000000000000000ph",
      pairedWithWatch: false,
      reportedAt: 1760400000000,
    },
    update: { pairedWithWatch: true },
  },
];

const entitiesByName = new Map(entities.map((entity) => [entity.name, entity]));

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

      const page = readChanges(sql, entitiesByName, 0, 100);
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
      // A sample's row stays until the alarm sweeps its tombstone (`Tombstones.test.ts`).
      assert.deepStrictEqual(
        sql.exec("SELECT id FROM tombstones ORDER BY id").map((row) => row["id"]),
        records.filter((record) => record.entity === "health_sample").map((record) => record.id),
      );
      for (const table of [
        "health_correlation",
        "health_characteristic",
        "health_activity_summary",
        "health_statistic",
        "health_statistics_device",
      ]) {
        assert.deepStrictEqual(sql.exec(`SELECT count(*) AS n FROM ${table}`), [{ n: 0 }]);
      }
    }),
  );

  it.effect("statistics are keyed by their device, type and bucket", () =>
    Effect.gen(function* () {
      const store = makeUserStore(makeTestStoreSql());
      const device = "dev_000000000000000000000000ph";
      const row = {
        device,
        type: "HKQuantityTypeIdentifierStepCount",
        bucketStart: 1760400000000,
        sum: 10,
        unit: "count",
      };
      const upsert = (id: string, overrides: Record<string, unknown> = {}): Mutation => ({
        entity: "health_statistic",
        op: "upsert",
        id,
        row: { ...row, ...overrides } as Mutation extends { row: infer R } ? R : never,
      });
      const failures = [
        // A different bucket than the ID's, a non-canonical bucket, and an off-grid bucket.
        upsert(`${device}/HKQuantityTypeIdentifierStepCount@1760400000000`, {
          bucketStart: 1760401800000,
        }),
        upsert(`${device}/HKQuantityTypeIdentifierStepCount@01760400000000`),
        upsert(`${device}/HKQuantityTypeIdentifierStepCount@1760400060000`, {
          bucketStart: 1760400060000,
        }),
      ];
      const messages: Array<string> = [];
      for (const mutation of failures) {
        messages.push((yield* Effect.flip(store.applyMutations([mutation]))).message);
      }
      assert.deepStrictEqual(messages, [
        `The ID must be ${device}/HKQuantityTypeIdentifierStepCount@1760401800000`,
        `The ID must be ${device}/HKQuantityTypeIdentifierStepCount@1760400000000`,
        "bucketStart must be a multiple of 30 minutes",
      ]);
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
          {
            entity: "health_sample",
            op: "upsert",
            id: "6f1c2a40-0000-4000-8000-000000000009",
            row: withoutSource,
          },
        ]),
      );
      assert.include(error.message, "sourceName");
    }),
  );

  it.effect("rejects IDs that aren't in each entity's form", () =>
    Effect.gen(function* () {
      const store = makeUserStore(makeTestStoreSql());
      const invalid: ReadonlyArray<Mutation> = [
        // HealthKit's `uuidString` is uppercase; records use it lowercased.
        {
          entity: "health_sample",
          op: "upsert",
          id: "6F1C2A40-0000-4000-8000-000000000001",
          row: steps,
        },
        { entity: "health_sample", op: "delete", id: "not-a-uuid" },
        { entity: "health_characteristic", op: "upsert", id: "DateOfBirth", row: { value: 1 } },
        { entity: "health_activity_summary", op: "upsert", id: "14/10/2026", row: {} },
      ];
      for (const mutation of invalid) {
        const error = yield* Effect.flip(store.applyMutations([mutation]));
        assert.include(error.message, "Invalid", mutation.id);
      }
    }),
  );

  it("stores samples by type and start, and indexes correlations by them", () => {
    const sql = makeTestStoreSql();
    makeUserStore(sql);
    const indexes = sql
      .exec("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'health_%'")
      .map((row) => row["name"]);
    assert.include(indexes, "health_correlation_type_start");
    assert.notInclude(indexes, "health_sample_type_start");
    const plan = (query: string) =>
      sql
        .exec(`EXPLAIN QUERY PLAN ${query}`, "HKQuantityTypeIdentifierStepCount", 0)
        .map((row) => row["detail"] as string)
        .join();
    // The table itself is in key order: a range of a type's samples is a search of it.
    const range = plan("SELECT id FROM health_sample WHERE type = ? AND start_date > ?");
    assert.include(range, "SEARCH health_sample USING PRIMARY KEY", range);
    const after = plan(
      "SELECT id FROM health_sample WHERE (type, start_date, id) > (?, ?, '') ORDER BY type, start_date, id",
    );
    assert.include(after, "SEARCH health_sample USING PRIMARY KEY", after);
    assert.notInclude(after, "TEMP B-TREE", after);
  });
});
