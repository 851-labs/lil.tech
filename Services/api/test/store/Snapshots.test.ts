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
  doUpkeep,
  latestSnapshot,
  nextAlarmAt,
  noteIngestion,
  nextSnapshotAt,
  readSnapshot,
  type SnapshotFiles,
  snapshotPolicy,
  writeSnapshotStep,
} from "../../src/store/Snapshots.ts";
import type { StoreSql } from "../../src/store/StoreSql.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";
import {
  makeTestSnapshotFiles,
  testNote,
  testNoteMutation,
  writeTestSnapshot,
} from "./TestUserStores.ts";

const day = 24 * 60 * 60 * 1000;
/** Tiny parts and pages, so a handful of records spans several of each. */
const policy = { ...snapshotPolicy, minChanges: 5, partRecords: 3, pageRows: 2, quietPeriod: 0 };

const note = testNoteMutation;
const all = [...entities, testNote];
const remove = (id: string): Mutation => ({ entity: "test_note", op: "delete", id });

const makeFiles = makeTestSnapshotFiles;

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
  between?: (step: number) => Effect.Effect<void, unknown>,
) => writeTestSnapshot(sql, files, policy, between);

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

      // Upkeep deletes it a week after it was replaced, whether or not the store changes.
      yield* TestClock.adjust("6 days");
      yield* doUpkeep(sql, files, yield* Clock.currentTimeMillis, policy);
      for (const key of firstKeys ?? []) assert.isTrue(stored.has(key));
      yield* TestClock.adjust("2 days");
      yield* doUpkeep(sql, files, yield* Clock.currentTimeMillis, policy);
      for (const key of firstKeys ?? []) assert.isFalse(stored.has(key));
      assert.isNull(readSnapshot(sql, first?.id ?? ""));
    }),
  );

  it.effect("an inactive store still gets its upkeep", () =>
    Effect.gen(function* () {
      const { sql, store, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      yield* writeSnapshot(sql, files);
      const now = yield* Clock.currentTimeMillis;
      // Nothing changes from here on, but the covered changes still need compacting.
      assert.strictEqual(nextAlarmAt(sql, now, policy), 30 * day);
    }),
  );

  it.effect("starts over if a deploy removes one of its entities midway", () =>
    Effect.gen(function* () {
      const { sql, store, stored, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      const now = yield* Clock.currentTimeMillis;
      // Write until it's in the middle of `test_note`, the last entity.
      for (let step = 0; step < 100; step++) {
        yield* writeSnapshotStep(sql, all, files, now, policy);
        if (stored.size > 0) break;
      }
      assert.isAbove(stored.size, 0);
      const result = yield* writeSnapshotStep(sql, entities, files, now, policy);
      assert.strictEqual(result, "idle");
      assert.strictEqual(stored.size, 0);
      assert.isNull(latestSnapshot(sql));
      assert.strictEqual(nextAlarmAt(sql, now, policy), now);
    }),
  );

  it.effect("uploads nothing if the store is deleted in between a part's pages", () =>
    Effect.gen(function* () {
      const { sql, store, stored, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      const now = yield* Clock.currentTimeMillis;
      // Up to `test_note`'s second part, which reads a page, gives up the event loop, then reads
      // another.
      for (let step = 0; step < 100; step++) {
        yield* writeSnapshotStep(sql, all, files, now, policy);
        if (stored.size > 0) break;
      }
      let puts = 0;
      const counted: SnapshotFiles = {
        ...files,
        put: (key, bytes) => Effect.sync(() => puts++).pipe(Effect.andThen(files.put(key, bytes))),
      };
      const [result] = yield* Effect.all(
        [
          writeSnapshotStep(sql, all, counted, now, policy),
          Effect.yieldNow.pipe(Effect.andThen(store.deleteAll()), Effect.orDie),
        ],
        { concurrency: 2 },
      );
      assert.strictEqual(result, "idle");
      assert.strictEqual(puts, 0);
      assert.strictEqual(stored.size, 0);
    }),
  );

  it.effect("ends a part early at its byte budget", () =>
    Effect.gen(function* () {
      const { sql, store, stored, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      // Any page goes over, so every part is one page.
      yield* writeTestSnapshot(sql, files, { ...policy, partBytes: 1 });
      const parts = readSnapshot(sql, latestSnapshot(sql)!.id)!.entities.find(
        (entity) => entity.entity === "test_note",
      )!.parts;
      assert.deepStrictEqual(
        parts.map((part) => part.records),
        [2, 2, 1],
      );
      assert.strictEqual(stored.size, 3);
    }),
  );

  it.effect("a part uploaded while the store is deleted is deleted too", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const stored = new Map<string, Uint8Array>();
      let store: ReturnType<typeof makeUserStore> | undefined;
      const files: SnapshotFiles = {
        // The account is deleted while the part uploads.
        put: (key, bytes) =>
          Effect.gen(function* () {
            stored.set(key, bytes);
            if (store !== undefined) yield* store.deleteAll().pipe(Effect.orDie);
          }),
        delete: (keys) => Effect.sync(() => keys.forEach((key) => stored.delete(key))),
      };
      store = makeUserStore(sql, [...entities, testNote], files);
      sql.script(createEntityTable(testNote));
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      yield* writeSnapshot(sql, files);
      assert.strictEqual(stored.size, 0);
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

  it.effect("deletes a chunk at a time, so one alarm can't hold the store for long", () =>
    Effect.gen(function* () {
      const { sql, store, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      yield* writeSnapshot(sql, files);
      yield* TestClock.adjust("31 days");
      const chunked = { ...policy, compactionChunk: 2 };
      const seqs = () => sql.exec("SELECT seq FROM changes ORDER BY seq").map((row) => row["seq"]);

      compactChanges(sql, yield* Clock.currentTimeMillis, chunked);
      assert.deepStrictEqual(seqs(), [3, 4, 5]);
      compactChanges(sql, yield* Clock.currentTimeMillis, chunked);
      assert.deepStrictEqual(seqs(), [5]);
      // The horizon moves with each chunk, so readers behind it learn they're compacted.
      assert.strictEqual((readChanges(sql, 3, 10) as { _tag?: string })._tag, "ChangesCompacted");
      compactChanges(sql, yield* Clock.currentTimeMillis, chunked);
      assert.deepStrictEqual(seqs(), []);
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
  it.effect("is never set for the time it's running at, which would clear it", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations(
        Array.from({ length: snapshotPolicy.minChanges }, (_, n) => note(`n${n}`)),
      );
      const now = yield* Clock.currentTimeMillis;
      // Due, but changes just arrived: once they've stopped for the quiet period.
      const quiet = now + snapshotPolicy.quietPeriod;
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), quiet);
      yield* store.alarm();
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), quiet);
    }),
  );

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

  it.effect("waits for uploads to go quiet before snapshotting", () =>
    Effect.gen(function* () {
      const { sql, store, files } = makeStore();
      const quiet = { ...policy, quietPeriod: 120_000 };
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      const start = yield* Clock.currentTimeMillis;
      // Due, but changes are still arriving: not yet.
      assert.strictEqual(nextSnapshotAt(sql, start, quiet), start + 120_000);
      assert.strictEqual(yield* writeSnapshotStep(sql, all, files, start, quiet), "idle");
      // More arrive a minute later: the wait starts over from them.
      yield* TestClock.adjust("1 minute");
      yield* store.applyMutations([note("f")]);
      const later = yield* Clock.currentTimeMillis;
      assert.strictEqual(nextSnapshotAt(sql, later, quiet), later + 120_000);
      // Two quiet minutes later, it's due.
      yield* TestClock.adjust("2 minutes");
      assert.strictEqual(nextSnapshotAt(sql, later + 120_000, quiet), later + 120_000);
    }),
  );

  it.effect("snapshots a store that never goes quiet within the maximum deferral", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      const quiet = { ...policy, quietPeriod: 120_000, maxDeferral: 10 * 60_000 };
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      const due = yield* Clock.currentTimeMillis;
      // A change every minute, never two quiet minutes in a row.
      for (let minute = 0; minute < 12; minute++) {
        yield* TestClock.adjust("1 minute");
        yield* store.applyMutations([note(`m${minute}`)]);
      }
      const now = yield* Clock.currentTimeMillis;
      assert.strictEqual(nextSnapshotAt(sql, now, quiet), now);
      assert.isAtLeast(now, due + quiet.maxDeferral);
    }),
  );

  it.effect("a snapshot in progress pauses while uploads arrive", () =>
    Effect.gen(function* () {
      const { sql, store, stored, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      const now = yield* Clock.currentTimeMillis;
      // Started with no quiet period, so it's under way.
      assert.strictEqual(yield* writeSnapshotStep(sql, all, files, now, policy), "continue");
      const quiet = { ...policy, quietPeriod: 120_000 };
      yield* store.applyMutations([note("f")]);
      const written = stored.size;
      assert.strictEqual(yield* writeSnapshotStep(sql, all, files, now, quiet), "idle");
      assert.strictEqual(stored.size, written);
      assert.strictEqual(nextAlarmAt(sql, now, quiet), now + 120_000);
    }),
  );

  it.effect("a paused snapshot carries on within the maximum deferral if uploads never stop", () =>
    Effect.gen(function* () {
      const { sql, store, files } = makeStore();
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      const start = yield* Clock.currentTimeMillis;
      assert.strictEqual(yield* writeSnapshotStep(sql, all, files, start, policy), "continue");
      const quiet = { ...policy, quietPeriod: 120_000, maxDeferral: 10 * 60_000 };
      // A change every minute.
      for (let minute = 0; minute < 12; minute++) {
        yield* TestClock.adjust("1 minute");
        yield* store.applyMutations([note(`m${minute}`)]);
      }
      const now = yield* Clock.currentTimeMillis;
      assert.strictEqual(yield* writeSnapshotStep(sql, all, files, now, quiet), "continue");
    }),
  );

  it.effect("uploads that change nothing still count as ingesting", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      const quiet = { ...policy, quietPeriod: 120_000 };
      yield* store.applyMutations(["a", "b", "c", "d", "e"].map((id) => note(id)));
      yield* TestClock.adjust("5 minutes");
      const now = yield* Clock.currentTimeMillis;
      assert.strictEqual(nextSnapshotAt(sql, now, quiet), now);
      // A batch sent again: nothing changes, but the store is busy with it.
      noteIngestion(sql, now);
      assert.strictEqual(nextSnapshotAt(sql, now, quiet), now + 120_000);
    }),
  );

  it.effect("the more a store holds, the more must change before the next snapshot", () =>
    Effect.gen(function* () {
      const { sql, store, files } = makeStore();
      const share = { ...policy, minChanges: 2, changeShare: 0.5 };
      yield* store.applyMutations(["a", "b", "c", "d", "e", "f", "g", "h"].map((id) => note(id)));
      yield* writeTestSnapshot(sql, files, share);
      const week = 7 * day;
      // 8 records: half of them must change. 3 changes aren't enough...
      yield* store.applyMutations(["a", "b", "c"].map((id) => note(id, "edited")));
      const now = yield* Clock.currentTimeMillis;
      assert.strictEqual(nextSnapshotAt(sql, now, share), now + week);
      // ...4 are.
      yield* store.applyMutations([note("d", "edited")]);
      assert.strictEqual(nextSnapshotAt(sql, now, share), now);
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
