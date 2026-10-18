import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { readHead } from "../../src/store/ChangeLog.ts";
import { createEntityTable } from "../../src/store/Entities.ts";
import {
  exportInterval,
  exportSnapshot,
  readExportRequest,
  requestExport,
} from "../../src/store/Exports.ts";
import { entities } from "../../src/store/Registry.ts";
import { latestSnapshot, nextSnapshotAt, snapshotPolicy } from "../../src/store/Snapshots.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";
import {
  makeTestSnapshotFiles,
  testNote,
  testNoteMutation,
  writeTestSnapshot,
} from "./TestUserStores.ts";

// Synthetic data only (AGENTS.md).
const day = 24 * 60 * 60 * 1000;
/** Snapshots would otherwise wait for 50,000 changes or a week. */
const policy = { ...snapshotPolicy, quietPeriod: 0 };

const makeStore = () => {
  const sql = makeTestStoreSql();
  const { files } = makeTestSnapshotFiles();
  const store = makeUserStore(sql, [...entities, testNote], files);
  sql.script(createEntityTable(testNote));
  return { sql, store, files };
};

const status = (sql: ReturnType<typeof makeStore>["sql"]) => {
  const request = readExportRequest(sql);
  return request === null ? null : exportSnapshot(sql, request, latestSnapshot(sql));
};

describe("data exports", () => {
  it.effect("asking makes a snapshot due at once, and it's ready once one covers it", () =>
    Effect.gen(function* () {
      const { sql, store, files } = makeStore();
      yield* store.applyMutations([testNoteMutation("a"), testNoteMutation("b")]);
      // The test clock's, which stays at 0.
      const now = 0;
      // Two changes aren't enough for a snapshot of their own.
      assert.isAbove(nextSnapshotAt(sql, now, policy) ?? 0, now + day);

      requestExport(sql, now);
      assert.strictEqual(nextSnapshotAt(sql, now, policy), now);
      assert.deepStrictEqual(status(sql), { ready: false, snapshot: null });

      // Changes after asking don't hold it up.
      yield* store.applyMutations([testNoteMutation("c")]);
      yield* writeTestSnapshot(sql, files, policy);
      const ready = status(sql);
      assert.isTrue(ready?.ready);
      assert.strictEqual(ready?.snapshot?.seq, readHead(sql));
    }),
  );

  it.effect("asking again within a day gets the same export, and a day later a new one", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations([testNoteMutation("a")]);
      const first = requestExport(sql, 1_000);
      yield* store.applyMutations([testNoteMutation("b")]);
      assert.deepStrictEqual(requestExport(sql, 1_000 + exportInterval - 1), first);
      assert.deepStrictEqual(requestExport(sql, 1_000 + exportInterval), {
        requestedAt: 1_000 + exportInterval,
        seq: 2,
      });
    }),
  );

  it.effect("an empty store's export is ready at once, with no snapshot", () =>
    Effect.sync(() => {
      const { sql } = makeStore();
      requestExport(sql, 1_000);
      assert.deepStrictEqual(status(sql), { ready: true, snapshot: null });
      assert.isNull(nextSnapshotAt(sql, 1_000, policy));
    }),
  );

  it.effect("the store's RPC asks for an export and reports it", () =>
    Effect.gen(function* () {
      const { store } = makeStore();
      assert.isNull(yield* store.exportStatus());
      yield* store.applyMutations([testNoteMutation("a")]);
      const asked = yield* store.requestExport();
      assert.include(asked, { seq: 1, ready: false });
      assert.deepStrictEqual(yield* store.exportStatus(), asked);
    }),
  );
});
