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
  provenance: null,
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

/** A heart rate series' values (851-4149): two instants and a reading 6 s long. */
const heartRateSeries = {
  type: "HKQuantityTypeIdentifierHeartRate",
  startDate: 1760400000000,
  count: 3,
  times: [0, 5, 10.5],
  durations: [0, 0, 6],
  values: [61, 140.5, 88],
  minimum: 61,
  maximum: 140.5,
  mostRecent: 88,
  mostRecentStartDate: 1760400010500,
  mostRecentEndDate: 1760400016500,
};

/** A workout's samples (851-4153): two heart rates and an energy sample. */
const workoutSamples = {
  count: 3,
  samples: {
    HKQuantityTypeIdentifierHeartRate: [
      "6f1c2a40-0000-4000-8000-000000000021",
      "6f1c2a40-0000-4000-8000-000000000022",
    ],
    HKQuantityTypeIdentifierActiveEnergyBurned: ["6f1c2a40-0000-4000-8000-000000000023"],
  },
};

/** A swim-bike-run's effort scores (851-4153): the whole race's, and its swim's. */
const workoutEffort = {
  samples: ["6f1c2a40-0000-4000-8000-000000000031", "6f1c2a40-0000-4000-8000-000000000032"],
  mostRelevant: "6f1c2a40-0000-4000-8000-000000000032",
  legs: [
    {
      activity: "6f1c2a40-0000-4000-8000-000000000033",
      samples: ["6f1c2a40-0000-4000-8000-000000000034"],
      mostRelevant: "6f1c2a40-0000-4000-8000-000000000034",
    },
  ],
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
    entity: "health_provenance",
    id: "0123456789abcdef0123456789abcdef",
    row: { sourceRevision: provenance.sourceRevision, device: provenance.device },
    update: { device: null },
  },
  {
    // From an iPhone that sends its source revision and device once (851-2674).
    entity: "health_sample",
    id: "6f1c2a40-0000-4000-8000-00000000000a",
    row: {
      ...steps,
      sourceRevision: null,
      device: null,
      provenance: "0123456789abcdef0123456789abcdef",
    },
    update: { type: steps.type, startDate: steps.startDate, value: 416 },
  },
  {
    entity: "health_quantity_series",
    id: "6f1c2a40-0000-4000-8000-00000000000b",
    row: heartRateSeries,
    update: { values: [61, 140.5, 89] },
  },
  {
    entity: "health_workout_samples",
    id: "6f1c2a40-0000-4000-8000-000000000010",
    row: workoutSamples,
    update: { count: 0, samples: {} },
  },
  {
    entity: "health_workout_effort",
    id: "6f1c2a40-0000-4000-8000-000000000011",
    row: workoutEffort,
    update: { mostRelevant: null },
  },
  {
    entity: "health_electrocardiogram_symptoms",
    id: "6f1c2a40-0000-4000-8000-000000000012",
    row: {
      count: 1,
      samples: {
        HKCategoryTypeIdentifierChestTightnessOrPain: ["6f1c2a40-0000-4000-8000-000000000041"],
      },
    },
    update: { count: 0, samples: {} },
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

      // The log serves each record's current row (`docs/sync/protocol.md`), so it's read after each
      // step.
      const read = (after: number) => {
        const page = readChanges(sql, entitiesByName, after, 100);
        return "changes" in page ? page.changes : assert.fail("compacted");
      };
      const n = records.length;
      yield* store.applyMutations(upserts("row"));
      const inserted = read(0);
      yield* store.applyMutations(upserts("update"));
      const updated = read(n);
      yield* store.applyMutations(
        records.map((record): Mutation => ({ entity: record.entity, op: "delete", id: record.id })),
      );
      const deleted = read(2 * n);
      // Once deleted, their earlier upserts read as deletes too.
      const all = read(0);
      assert.lengthOf(all, 3 * n);
      records.forEach((record, index) => {
        assert.deepStrictEqual(
          inserted[index]?.row,
          { id: record.id, ...record.row },
          record.entity,
        );
        assert.deepStrictEqual(
          updated[index]?.row,
          { id: record.id, ...record.row, ...record.update },
          record.entity,
        );
        assert.deepInclude(deleted[index], { entity: record.entity, id: record.id, op: "delete" });
        assert.deepInclude(all[index], { entity: record.entity, id: record.id, op: "delete" });
      });
      // A sample's row stays until the alarm sweeps its tombstone (`Tombstones.test.ts`).
      assert.deepStrictEqual(
        sql.exec("SELECT id FROM tombstones ORDER BY id").map((row) => row["id"]),
        records.filter((record) => record.entity === "health_sample").map((record) => record.id),
      );
      for (const table of [
        "health_quantity_series",
        "health_workout_samples",
        "health_workout_effort",
        "health_electrocardiogram_symptoms",
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

  it.effect("deleting a sample deletes its series", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      const id = "6f1c2a40-0000-4000-8000-00000000000d";
      const single = "6f1c2a40-0000-4000-8000-00000000000e";
      yield* store.applyMutations([
        {
          entity: "health_sample",
          op: "upsert",
          id,
          row: { ...steps, type: heartRateSeries.type, value: 118.4, unit: "count/min" },
        },
        { entity: "health_quantity_series", op: "upsert", id, row: heartRateSeries },
        { entity: "health_sample", op: "upsert", id: single, row: steps },
      ]);
      yield* store.applyMutations([
        { entity: "health_sample", op: "delete", id },
        { entity: "health_sample", op: "delete", id: single },
      ]);
      const page = readChanges(sql, entitiesByName, 3, 100);
      const changes = "changes" in page ? page.changes : assert.fail("compacted");
      // The series' delete is logged too, so the Macs delete it; a sample without one logs only
      // its own.
      assert.deepStrictEqual(
        changes.map((change) => [change.entity, change.id, change.op]),
        [
          ["health_sample", id, "delete"],
          ["health_quantity_series", id, "delete"],
          ["health_sample", single, "delete"],
        ],
      );
      assert.deepStrictEqual(sql.exec("SELECT count(*) AS n FROM health_quantity_series"), [
        { n: 0 },
      ]);
    }),
  );

  it.effect("deleting a workout or an ECG deletes its links", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      const workout = "6f1c2a40-0000-4000-8000-000000000050";
      const ecg = "6f1c2a40-0000-4000-8000-000000000051";
      const source = { sourceName: "Test Watch", sourceBundleId: "com.apple.health.00000000" };
      yield* store.applyMutations([
        {
          entity: "health_workout",
          op: "upsert",
          id: workout,
          row: {
            activityType: 37,
            startDate: 1760400000000,
            endDate: 1760401800000,
            duration: 1740,
            activities: [],
            events: [],
            statistics: {},
            ...source,
          },
        },
        { entity: "health_workout_samples", op: "upsert", id: workout, row: workoutSamples },
        { entity: "health_workout_effort", op: "upsert", id: workout, row: workoutEffort },
        {
          entity: "health_electrocardiogram",
          op: "upsert",
          id: ecg,
          row: {
            startDate: 1760400000000,
            endDate: 1760400030000,
            classification: 1,
            symptomsStatus: 1,
            averageHeartRate: 62,
            samplingFrequency: null,
            voltageCount: 0,
            voltages: null,
            ...source,
          },
        },
        {
          entity: "health_electrocardiogram_symptoms",
          op: "upsert",
          id: ecg,
          row: { count: 0, samples: {} },
        },
      ] as ReadonlyArray<Mutation>);
      yield* store.applyMutations([
        { entity: "health_workout", op: "delete", id: workout },
        { entity: "health_electrocardiogram", op: "delete", id: ecg },
      ]);
      const page = readChanges(sql, entitiesByName, 5, 100);
      const changes = "changes" in page ? page.changes : assert.fail("compacted");
      // Each link's delete is logged too, so the Macs delete it.
      assert.deepStrictEqual(
        changes.map((change) => [change.entity, change.id, change.op]),
        [
          ["health_workout", workout, "delete"],
          ["health_workout_samples", workout, "delete"],
          ["health_workout_effort", workout, "delete"],
          ["health_electrocardiogram", ecg, "delete"],
          ["health_electrocardiogram_symptoms", ecg, "delete"],
        ],
      );
      for (const table of [
        "health_workout_samples",
        "health_workout_effort",
        "health_electrocardiogram_symptoms",
      ]) {
        assert.deepStrictEqual(sql.exec(`SELECT count(*) AS n FROM ${table}`), [{ n: 0 }]);
      }
    }),
  );

  it.effect("keeps links only in their documented shape", () =>
    Effect.gen(function* () {
      const store = makeUserStore(makeTestStoreSql());
      const upsert = (entity: string, row: Record<string, unknown>): Mutation => ({
        entity,
        op: "upsert",
        id: "6f1c2a40-0000-4000-8000-000000000060",
        row: row as Mutation extends { row: infer R } ? R : never,
      });
      // Too many to upload: the count alone.
      yield* store.applyMutations([
        upsert("health_workout_samples", { count: 25_000, samples: null }),
      ]);
      const heartRates = workoutSamples.samples.HKQuantityTypeIdentifierHeartRate;
      const invalid: ReadonlyArray<readonly [string, Record<string, unknown>, string]> = [
        ["health_workout_samples", { ...workoutSamples, count: -1 }, "non-negative"],
        ["health_workout_samples", { ...workoutSamples, count: 2 }, "number of samples"],
        ["health_workout_samples", { ...workoutSamples, samples: heartRates }, "an object"],
        [
          "health_electrocardiogram_symptoms",
          {
            count: 1,
            samples: { HKCategoryTypeIdentifierFatigue: ["6F1C2A40-0000-4000-8000-000000000061"] },
          },
          "lowercase UUIDs",
        ],
        ["health_workout_effort", { ...workoutEffort, samples: "x" }, "samples"],
        ["health_workout_effort", { ...workoutEffort, mostRelevant: 7 }, "mostRelevant"],
        [
          "health_workout_effort",
          { ...workoutEffort, legs: [{ activity: "swim", samples: [] }] },
          "each leg",
        ],
      ];
      for (const [entity, row, message] of invalid) {
        const error = yield* Effect.flip(store.applyMutations([upsert(entity, row)]));
        assert.include(error.message, message, entity);
      }
    }),
  );

  it.effect("keeps a series' values only in their documented shape", () =>
    Effect.gen(function* () {
      const store = makeUserStore(makeTestStoreSql());
      const upsert = (row: Record<string, unknown>): Mutation => ({
        entity: "health_quantity_series",
        op: "upsert",
        id: "6f1c2a40-0000-4000-8000-00000000000c",
        row: row as Mutation extends { row: infer R } ? R : never,
      });
      // Too many to upload: the count and summary alone.
      yield* store.applyMutations([
        upsert({ ...heartRateSeries, times: null, durations: null, values: null }),
      ]);
      const invalid: ReadonlyArray<readonly [Record<string, unknown>, string]> = [
        [{ ...heartRateSeries, count: 1 }, "count"],
        [{ ...heartRateSeries, values: null }, "all null"],
        [{ ...heartRateSeries, values: [61, 140.5] }, "one entry per value"],
        [{ ...heartRateSeries, times: [0, 10.5, 5] }, "in order"],
        [{ ...heartRateSeries, times: [-1, 5, 10.5] }, "non-negative"],
        [{ ...heartRateSeries, durations: [0, -1, 6] }, "durations"],
        [{ ...heartRateSeries, values: [61, "140.5", 88] }, "numbers"],
      ];
      for (const [row, message] of invalid) {
        const error = yield* Effect.flip(store.applyMutations([upsert(row)]));
        assert.include(error.message, message);
      }
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
