import { gunzipSync } from "node:zlib";
import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { applyMutations, readChanges } from "../../src/store/ChangeLog.ts";
import { InvalidMutation, type Mutation } from "../../src/store/Changes.ts";
import { migrate, storeMigrations } from "../../src/store/Migrations.ts";
import { entities } from "../../src/store/Registry.ts";
import {
  latestSnapshot,
  noteIngestion,
  snapshotPolicy,
  writeSnapshotStep,
} from "../../src/store/Snapshots.ts";
import type { StoreSql } from "../../src/store/StoreSql.ts";
import {
  nextTombstoneSweepAt,
  sweepTombstones,
  tombstonePolicy,
} from "../../src/store/Tombstones.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";
import { makeTestSnapshotFiles } from "./TestUserStores.ts";

// Synthetic data only (AGENTS.md). Health samples are the entity with key fields.
const entitiesByName = new Map(entities.map((entity) => [entity.name, entity]));
const uuid = (n: number) => `6f1c2a40-0000-4000-8000-${String(n).padStart(12, "0")}`;
const steps = "HKQuantityTypeIdentifierStepCount";
type Row = Mutation extends { readonly row: infer R } ? R : never;

const sample = (n: number, overrides: Record<string, unknown> = {}): Mutation => ({
  entity: "health_sample",
  op: "upsert",
  id: uuid(n),
  row: {
    type: steps,
    startDate: 1760400000000 + n * 60000,
    endDate: 1760400060000 + n * 60000,
    value: n,
    unit: "count",
    sourceName: "Test iPhone",
    sourceBundleId: "com.apple.health.00000000",
    ...overrides,
  } as Row,
});
const remove = (n: number): Mutation => ({ entity: "health_sample", op: "delete", id: uuid(n) });

const makeStore = () => {
  const sql = makeTestStoreSql();
  migrate(sql);
  const apply = (mutations: ReadonlyArray<Mutation>, at = 0) =>
    applyMutations(sql, entitiesByName, mutations, at);
  return { sql, apply };
};

/** The samples stored, by number. */
const stored = (sql: StoreSql) =>
  sql
    .exec("SELECT id FROM health_sample ORDER BY id")
    .map((row) => Number((row["id"] as string).slice(-12)));

const tombstoned = (sql: StoreSql) =>
  sql
    .exec("SELECT id FROM tombstones ORDER BY id")
    .map((row) => Number((row["id"] as string).slice(-12)));

const log = (sql: StoreSql) => {
  const page = readChanges(sql, 0, 1000);
  if (!("changes" in page)) return assert.fail("compacted");
  return page.changes.map((change) => `${change.op} ${Number(change.id.slice(-12))}`);
};

describe("samples by type and start", () => {
  it("finds a sample by its type, start and ID, so re-uploading it changes nothing", () => {
    const { sql, apply } = makeStore();
    apply([sample(1), sample(2)]);
    assert.deepStrictEqual(apply([sample(1)]).appended, 0);
    assert.deepStrictEqual(apply([sample(1, { value: 10 })]).appended, 1);
    assert.deepStrictEqual(sql.exec("SELECT value FROM health_sample WHERE id = ?", uuid(1)), [
      { value: 10 },
    ]);
    assert.deepStrictEqual(log(sql), ["upsert 1", "upsert 2", "upsert 1"]);
  });

  it("refuses an upsert without its key fields", () => {
    const { apply } = makeStore();
    apply([sample(1)]);
    const partial: Mutation = {
      entity: "health_sample",
      op: "upsert",
      id: uuid(1),
      row: { value: 2 },
    };
    assert.throws(() => apply([partial]), InvalidMutation, "Missing type");
  });

  it("a delete leaves a tombstone and logs the delete once", () => {
    const { sql, apply } = makeStore();
    apply([sample(1), sample(2)]);
    assert.strictEqual(apply([remove(1)]).appended, 1);
    assert.strictEqual(apply([remove(1)]).appended, 0);
    // Its row stays until a sweep.
    assert.deepStrictEqual(stored(sql), [1, 2]);
    assert.deepStrictEqual(tombstoned(sql), [1]);
    // A record that was never stored can't be told apart, so its delete is logged too.
    assert.strictEqual(apply([remove(9)]).appended, 1);
    assert.deepStrictEqual(log(sql), ["upsert 1", "upsert 2", "delete 1", "delete 9"]);
  });

  it("an upsert after a delete brings the record back, as a new one", () => {
    const { sql, apply } = makeStore();
    apply([sample(1)]);
    apply([remove(1)]);
    // Merging with the deleted record's fields would revive them: it needs them all again.
    const keyOnly: Mutation = {
      entity: "health_sample",
      op: "upsert",
      id: uuid(1),
      row: { type: steps, startDate: 1760400000000 + 60000, value: 3 },
    };
    assert.throws(() => apply([keyOnly]), InvalidMutation, "Missing endDate");
    assert.deepStrictEqual(tombstoned(sql), [1]);
    // The same row as before is still a change: the record was deleted.
    assert.strictEqual(apply([sample(1)]).appended, 1);
    assert.deepStrictEqual(tombstoned(sql), []);
    assert.deepStrictEqual(log(sql), ["upsert 1", "delete 1", "upsert 1"]);
  });
});

describe("tombstone sweep", () => {
  const policy = { ...tombstonePolicy, delay: 1000, chunkRows: 2, stepInterval: 10 };
  /** Not waiting for uploads to stop, except in the test about that. */
  const quiet = { ...snapshotPolicy, quietPeriod: 0 };

  /** Runs sweep steps from `from`, a step interval apart, until the pass ends. */
  const sweep = (sql: StoreSql, from: number, between: (now: number) => void = () => {}) => {
    let now = from;
    for (let step = 0; step < 100; step++) {
      const going = sweepTombstones(sql, entities, now, policy, quiet);
      if (!going) return now;
      now += policy.stepInterval;
      between(now);
    }
    return assert.fail("The pass never ended");
  };

  it("removes tombstoned rows a chunk at a time, once the oldest tombstone is old enough", () => {
    const { sql, apply } = makeStore();
    apply([1, 2, 3, 4, 5, 6, 7].map((n) => sample(n)));
    apply([remove(2), remove(5), remove(6), remove(9)], 100);
    assert.isNull(nextTombstoneSweepAt(makeStore().sql, 0, policy, quiet));
    assert.strictEqual(nextTombstoneSweepAt(sql, 0, policy, quiet), 1100);
    assert.isFalse(sweepTombstones(sql, entities, 1099, policy, quiet));
    assert.deepStrictEqual(stored(sql), [1, 2, 3, 4, 5, 6, 7]);

    sweep(sql, 1100);
    assert.deepStrictEqual(stored(sql), [1, 3, 4, 7]);
    assert.deepStrictEqual(tombstoned(sql), []);
    assert.isNull(nextTombstoneSweepAt(sql, 2000, policy, quiet));
    // The log already had the deletes; sweeping adds nothing.
    assert.lengthOf(log(sql), 11);
  });

  it("keeps tombstones from during a pass for the next, and records brought back meanwhile", () => {
    const { sql, apply } = makeStore();
    apply([1, 2, 3, 4, 5, 6].map((n) => sample(n)));
    apply([remove(1), remove(6)], 0);
    sweep(sql, 1000, (now) => {
      // Behind the pass's cursor, and ahead of it.
      if (now === 1010) apply([remove(2), sample(6)], now);
    });
    assert.deepStrictEqual(stored(sql), [2, 3, 4, 5, 6]);
    assert.deepStrictEqual(tombstoned(sql), [2]);
    assert.strictEqual(nextTombstoneSweepAt(sql, 1100, policy, quiet), 2010);
    sweep(sql, 2010);
    assert.deepStrictEqual(stored(sql), [3, 4, 5, 6]);
  });

  it("waits while the store is taking in uploads", () => {
    const { sql, apply } = makeStore();
    apply([sample(1)]);
    apply([remove(1)]);
    const waiting = { ...snapshotPolicy, quietPeriod: 500 };
    noteIngestion(sql, 900);
    assert.strictEqual(nextTombstoneSweepAt(sql, 0, policy, waiting), 1400);
    assert.isFalse(sweepTombstones(sql, entities, 1000, policy, waiting));
    assert.deepStrictEqual(tombstoned(sql), [1]);
  });

  it("drops tombstones of an entity that no longer has key fields, rather than coming back", () => {
    const { sql, apply } = makeStore();
    apply([sample(1)]);
    apply([remove(1)]);
    const unkeyed = entities.filter((entity) => entity.name !== "health_sample");
    assert.isFalse(sweepTombstones(sql, unkeyed, 1000, policy, quiet));
    assert.deepStrictEqual(tombstoned(sql), []);
    assert.isNull(nextTombstoneSweepAt(sql, 1000, policy, quiet));
  });
});

describe("snapshots of samples", () => {
  const policy = { ...snapshotPolicy, minChanges: 1, partRecords: 3, pageRows: 2, quietPeriod: 0 };

  const records = (bytes: Uint8Array | undefined) =>
    gunzipSync(bytes ?? new Uint8Array())
      .toString()
      .trim()
      .split("\n")
      .filter((line) => line !== "")
      .map((line) => JSON.parse(line) as { id: string; type: string; startDate: number });

  it.effect("page in key order, leaving out tombstoned samples", () =>
    Effect.gen(function* () {
      const { sql, apply } = makeStore();
      const { stored: files, files: snapshotFiles } = makeTestSnapshotFiles();
      const heart = "HKQuantityTypeIdentifierHeartRate";
      apply([
        ...[1, 2, 3, 4].map((n) => sample(n)),
        // Same start as sample 1, another type, and a lower ID than the steps.
        ...[0, 5].map((n) => sample(n, { type: heart, startDate: 1760400000000 + 60000 })),
      ]);
      apply([remove(3)]);
      for (let step = 0; step < 100; step++) {
        if ((yield* writeSnapshotStep(sql, entities, snapshotFiles, 0, policy)) === "finished") {
          break;
        }
      }
      const snapshot = latestSnapshot(sql);
      const samples = snapshot?.entities.find((entity) => entity.entity === "health_sample");
      assert.isAbove(samples?.parts.length ?? 0, 1);
      const written = (samples?.parts ?? []).flatMap((part) => records(files.get(part.key)));
      assert.deepStrictEqual(
        written.map((record) => [record.type, Number(record.id.slice(-12))]),
        [
          [heart, 0],
          [heart, 5],
          [steps, 1],
          [steps, 2],
          [steps, 4],
        ],
      );
    }),
  );

  it.effect("start over from a cursor written before samples had key fields", () =>
    Effect.gen(function* () {
      const { sql, apply } = makeStore();
      const { stored: files, files: snapshotFiles } = makeTestSnapshotFiles();
      apply([1, 2, 3, 4, 5].map((n) => sample(n)));
      // Write until the job is on samples, then give it an old-style cursor (an ID).
      const index = entities.findIndex((entity) => entity.name === "health_sample");
      for (let step = 0; step < 100; step++) {
        yield* writeSnapshotStep(sql, entities, snapshotFiles, 0, policy);
        const job = sql.exec("SELECT entity_index FROM snapshot_job")[0];
        if (job?.["entity_index"] === index && files.size > 0) break;
      }
      sql.exec("UPDATE snapshot_job SET after_id = ?", uuid(2));
      assert.strictEqual(yield* writeSnapshotStep(sql, entities, snapshotFiles, 0, policy), "idle");
      assert.strictEqual(files.size, 0);
      assert.deepStrictEqual(sql.exec("SELECT id FROM snapshots"), []);
    }),
  );
});

describe("health_sample_by_time migration", () => {
  it("keeps the samples a store already had", () => {
    const sql = makeTestStoreSql();
    const before = storeMigrations.findIndex(
      (migration) => migration.name === "health_sample_by_time",
    );
    migrate(sql, storeMigrations.slice(0, before));
    for (const n of [2, 1]) {
      sql.exec(
        `INSERT INTO health_sample (id, type, start_date, end_date, source_name, source_bundle_id)
          VALUES (?, ?, ?, ?, 'Test iPhone', 'com.apple.health.00000000')`,
        uuid(n),
        steps,
        n,
        n + 1,
      );
    }
    migrate(sql);
    assert.deepStrictEqual(stored(sql), [1, 2]);
    assert.deepStrictEqual(
      sql.exec("SELECT name, pk FROM pragma_table_info('health_sample') WHERE pk > 0 ORDER BY pk"),
      [
        { name: "type", pk: 1 },
        { name: "start_date", pk: 2 },
        { name: "id", pk: 3 },
      ],
    );
    assert.deepStrictEqual(sql.exec("SELECT \"wr\" FROM pragma_table_list('health_sample')"), [
      { wr: 1 },
    ]);
  });
});
