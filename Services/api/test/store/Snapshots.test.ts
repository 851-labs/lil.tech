import { gunzipSync } from "node:zlib";
import { assert, describe, it } from "@effect/vitest";
import { Clock, Effect } from "effect";
import { TestClock } from "effect/testing";
import { readChanges, readHead } from "../../src/store/ChangeLog.ts";
import type { Mutation } from "../../src/store/Changes.ts";
import { createEntityTable } from "../../src/store/Entities.ts";
import { entities } from "../../src/store/Registry.ts";
import {
  compactChanges,
  latestSnapshot,
  nextSnapshotAt,
  type SnapshotFiles,
  snapshotPolicy,
  writeSnapshotStep,
} from "../../src/store/Snapshots.ts";
import type { StoreSql } from "../../src/store/StoreSql.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";
import { testNote } from "./TestUserStores.ts";

const day = 24 * 60 * 60 * 1000;
/** Tiny parts and pages, so a handful of records spans several of each. */
const policy = { ...snapshotPolicy, minChanges: 5, partRecords: 3, pageRows: 2 };

const note = (id: string, title = `Note ${id}`): Mutation => ({
  entity: "test_note",
  op: "upsert",
  id,
  row: { title, pinned: false, score: null, tags: [], createdAt: 1 },
});
const remove = (id: string): Mutation => ({ entity: "test_note", op: "delete", id });

const makeFiles = () => {
  const stored = new Map<string, Uint8Array>();
  const files: SnapshotFiles = {
    put: (key, bytes) => Effect.sync(() => void stored.set(key, bytes)),
    delete: (keys) => Effect.sync(() => keys.forEach((key) => stored.delete(key))),
  };
  return { stored, files };
};

const makeStore = () => {
  const sql = makeTestStoreSql();
  const { stored, files } = makeFiles();
  const store = makeUserStore(sql, [...entities, testNote], files);
  sql.script(createEntityTable(testNote));
  return { sql, store, stored, files };
};

/** Runs snapshot steps until one finishes, running `between` after each part. */
const writeSnapshot = (
  sql: StoreSql,
  files: SnapshotFiles,
  between: (step: number) => Effect.Effect<void, unknown> = () => Effect.void,
) =>
  Effect.gen(function* () {
    for (let step = 0; step < 1000; step++) {
      const now = yield* Clock.currentTimeMillis;
      const result = yield* writeSnapshotStep(sql, [...entities, testNote], files, now, policy);
      if (result !== "continue") return result;
      yield* between(step);
    }
    return assert.fail("The snapshot never finished");
  });

type Replica = Map<string, unknown>;

/** Applies log changes to a replica the way a client does. */
const applyLog = (sql: StoreSql, replica: Replica, after: number) => {
  const page = readChanges(sql, after, 100_000);
  if (!("changes" in page)) return assert.fail("compacted");
  for (const change of page.changes) {
    if (change.entity !== "test_note") continue;
    if (change.op === "upsert") replica.set(change.id, change.row);
    else replica.delete(change.id);
  }
  return replica;
};

describe("snapshots", () => {
  it.effect("a snapshot plus the changes after it equals replaying the whole log", () =>
    Effect.gen(function* () {
      const { sql, store, stored, files } = makeStore();
      yield* store.applyMutations(["b", "d", "f", "h", "j", "l", "n"].map((id) => note(id)));
      yield* store.applyMutations([remove("d"), note("f", "F, edited")]);

      // Writes keep landing while the snapshot is written, before and after its cursor.
      const writes = [
        [note("a"), note("b", "B, edited")],
        [remove("j"), note("z")],
        [note("c"), remove("n")],
        [note("l", "L, edited")],
      ];
      const result = yield* writeSnapshot(sql, files, (step) =>
        step < writes.length
          ? store.applyMutations(writes[step] ?? []).pipe(Effect.asVoid)
          : Effect.void,
      );
      assert.strictEqual(result, "finished");

      const snapshot = latestSnapshot(sql);
      if (snapshot === null) return assert.fail("no snapshot");
      const notes = snapshot.entities.find((entity) => entity.entity === "test_note");
      assert.isAbove(notes?.parts.length ?? 0, 1);
      for (const part of notes?.parts ?? []) {
        const bytes = stored.get(part.key);
        assert.strictEqual(bytes?.length, part.bytes);
        assert.strictEqual(
          part.records,
          gunzipSync(bytes ?? new Uint8Array())
            .toString()
            .trim()
            .split("\n").length,
        );
      }
      // Every entity appears, even empty ones.
      assert.includeMembers(
        snapshot.entities.map((entity) => entity.entity),
        ["health_sample", "test_note"],
      );

      const fromSnapshot: Replica = new Map();
      for (const part of notes?.parts ?? []) {
        const lines = gunzipSync(stored.get(part.key) ?? new Uint8Array())
          .toString()
          .trim()
          .split("\n");
        for (const line of lines) {
          const record = JSON.parse(line) as { id: string };
          fromSnapshot.set(record.id, record);
        }
      }
      applyLog(sql, fromSnapshot, snapshot.seq);
      const fromLog = applyLog(sql, new Map(), 0);
      const sorted = (replica: Replica) =>
        [...replica.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
      assert.deepStrictEqual(sorted(fromSnapshot), sorted(fromLog));
      assert.isAbove(fromLog.size, 5);
    }),
  );

  it.effect("is due after enough changes, or a week after the last one if anything changed", () =>
    Effect.gen(function* () {
      const { sql, store, files } = makeStore();
      assert.isNull(nextSnapshotAt(sql, 0, policy));
      yield* store.applyMutations([note("a")]);
      assert.strictEqual(nextSnapshotAt(sql, 0, policy), 7 * day);
      yield* store.applyMutations(["b", "c", "d", "e"].map((id) => note(id)));
      assert.strictEqual(nextSnapshotAt(sql, 0, policy), 0);

      yield* writeSnapshot(sql, files);
      const now = yield* Clock.currentTimeMillis;
      assert.isNull(nextSnapshotAt(sql, now, policy));
      yield* store.applyMutations([note("f")]);
      assert.strictEqual(nextSnapshotAt(sql, now, policy), now + 7 * day);
    }),
  );

  it.effect("replacing a snapshot keeps the old one for a week, then deletes its parts", () =>
    Effect.gen(function* () {
      const { sql, store, stored, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      yield* writeSnapshot(sql, files);
      const first = latestSnapshot(sql);
      const firstKeys = first?.entities.flatMap((entity) => entity.parts.map((part) => part.key));

      yield* store.applyMutations(["f", "g", "h", "i", "j"].map((id) => note(id)));
      yield* writeSnapshot(sql, files);
      assert.notStrictEqual(latestSnapshot(sql)?.id, first?.id);
      for (const key of firstKeys ?? []) assert.isTrue(stored.has(key));

      yield* TestClock.adjust("8 days");
      yield* store.applyMutations(["k", "l", "m", "n", "o"].map((id) => note(id)));
      yield* writeSnapshot(sql, files);
      for (const key of firstKeys ?? []) assert.isFalse(stored.has(key));
    }),
  );
});

describe("compaction", () => {
  it.effect(
    "deletes old changes the snapshot covers, never newer ones, and raises the horizon",
    () =>
      Effect.gen(function* () {
        const { sql, store, files } = makeStore();
        yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
        yield* TestClock.adjust("31 days");
        yield* store.applyMutations([note("f")]);
        yield* writeSnapshot(sql, files);
        const snapshot = latestSnapshot(sql);
        yield* store.applyMutations([note("g")]);

        // Changes 1-5 are older than 30 days and covered; 6 is covered but recent; 7 is newer.
        yield* TestClock.adjust("1 day");
        compactChanges(sql, yield* Clock.currentTimeMillis, policy);
        const remaining = sql.exec("SELECT seq FROM changes ORDER BY seq").map((row) => row["seq"]);
        assert.deepStrictEqual(remaining, [6, 7]);
        assert.strictEqual(snapshot?.seq, 6);
        assert.strictEqual((readChanges(sql, 0, 10) as { _tag?: string })._tag, "ChangesCompacted");
        assert.lengthOf(
          (readChanges(sql, 5, 10) as unknown as { changes: Array<unknown> }).changes,
          2,
        );

        // Even long after, nothing past the snapshot goes.
        yield* TestClock.adjust("100 days");
        compactChanges(sql, yield* Clock.currentTimeMillis, policy);
        assert.deepStrictEqual(
          sql.exec("SELECT seq FROM changes ORDER BY seq").map((row) => row["seq"]),
          [7],
        );
        assert.strictEqual(readHead(sql), 7);
      }),
  );

  it.effect("does nothing without a snapshot", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations([note("a")]);
      compactChanges(sql, 1000 * day, policy);
      assert.strictEqual(sql.exec("SELECT count(*) AS n FROM changes")[0]?.["n"], 1);
    }),
  );
});

describe("the store's alarm", () => {
  it.effect("is set when a snapshot is due, and writes it a step per alarm", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations([note("a")]);
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), 7 * day);

      yield* TestClock.adjust("7 days");
      for (let step = 0; step < 100 && latestSnapshot(sql) === null; step++) {
        yield* store.alarm();
      }
      assert.isNotNull(latestSnapshot(sql));
    }),
  );

  it.effect("deleteAll deletes the snapshot files too", () =>
    Effect.gen(function* () {
      const { sql, store, stored, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      yield* writeSnapshot(sql, files);
      assert.isAbove(stored.size, 0);
      yield* store.deleteAll();
      assert.strictEqual(stored.size, 0);
    }),
  );
});
