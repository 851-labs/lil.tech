import { assert, describe, it } from "@effect/vitest";
import { Effect, Exit } from "effect";
import type { UserId } from "../../src/core/Ids.ts";
import { migrate, type StoreMigration, storeMigrations } from "../../src/store/Migrations.ts";
import { fromDurableObjectStorage, type StoreSql } from "../../src/store/StoreSql.ts";
import { StorageFull } from "../../src/store/Changes.ts";
import {
  makeUserStore,
  storageHardLimitBytes,
  storageQuotaBytes,
  type UserStoreMethods,
  userStoreErrors,
} from "../../src/store/UserStore.ts";
import { entities } from "../../src/store/Registry.ts";
import { UserStores } from "../../src/store/UserStores.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";

const tables = (sql: StoreSql) =>
  sql
    .exec("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    .map((row) => row["name"]);

const first: StoreMigration = { version: 1, name: "a", sql: "CREATE TABLE a (x TEXT);" };
const second: StoreMigration = {
  version: 2,
  name: "b",
  sql: "CREATE TABLE b (x TEXT); INSERT INTO a VALUES ('from 2');",
};

describe("migrate", () => {
  it("brings a fresh store to the latest version", () => {
    const sql = makeTestStoreSql();
    assert.strictEqual(migrate(sql), storeMigrations.length);
    assert.includeMembers(tables(sql), ["meta", "store_migrations"]);
    // Running again changes nothing.
    assert.strictEqual(migrate(sql), storeMigrations.length);
    assert.lengthOf(sql.exec("SELECT * FROM store_migrations"), storeMigrations.length);
  });

  it("applies only the migrations a store at an older version is missing", () => {
    const sql = makeTestStoreSql();
    assert.strictEqual(migrate(sql, [first]), 1);
    // `first` isn't idempotent, so running it again would throw.
    assert.strictEqual(migrate(sql, [first, second]), 2);
    assert.deepStrictEqual(
      sql.exec("SELECT version, name FROM store_migrations ORDER BY version"),
      [
        { version: 1, name: "a" },
        { version: 2, name: "b" },
      ],
    );
    assert.deepStrictEqual(sql.exec("SELECT x FROM a"), [{ x: "from 2" }]);
  });

  it("rolls back a failed migration, keeping the versions before it", () => {
    const sql = makeTestStoreSql();
    const broken = { ...second, sql: "CREATE TABLE b (x TEXT); INSERT INTO nope VALUES (1);" };
    assert.throws(() => migrate(sql, [first, broken]), /nope/);
    assert.notInclude(tables(sql), "b");
    assert.strictEqual(migrate(sql, [first, second]), 2);
  });

  it("refuses a store whose history doesn't match", () => {
    const sql = makeTestStoreSql();
    migrate(sql, [first]);
    assert.throws(() => migrate(sql, [{ ...first, name: "renamed" }]), /history conflict/);
  });

  it("tolerates a store migrated by newer code", () => {
    const sql = makeTestStoreSql();
    migrate(sql, [first, second]);
    assert.strictEqual(migrate(sql, [first]), 2);
  });

  it("refuses migrations that aren't numbered 1, 2, 3…", () => {
    const sql = makeTestStoreSql();
    assert.throws(() => migrate(sql, [first, { ...second, version: 3 }]), /numbered 3/);
    assert.throws(() => migrate(sql, [second, first]), /numbered 2/);
    assert.deepStrictEqual(tables(sql), []);
  });
});

describe("makeUserStore", () => {
  it.effect("migrates when the store starts", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      assert.include(tables(sql), "meta");
      assert.strictEqual(yield* store.schemaVersion(), storeMigrations.length);
    }),
  );

  it.effect("deleteAll marks the store deleted at once, and its alarm empties it", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      sql.exec("INSERT INTO meta (key, value) VALUES ('epoch', '3')");
      yield* store.applyMutations([
        {
          entity: "health_characteristic",
          op: "upsert",
          id: "HKCharacteristicTypeIdentifierBiologicalSex",
          row: { value: "female" },
        },
      ]);
      yield* store.deleteAll();
      // Deleted, not yet emptied: the alarm is due right away.
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), 1);
      assert.lengthOf(sql.exec("SELECT * FROM health_characteristic"), 1);
      assert.strictEqual(
        (yield* Effect.flip(store.receiveHealthBatch("00000000-0000-4000-8000-000000000002")))._tag,
        "AccountDeleted",
      );
      yield* store.alarm();
      // Only the mark that the account is gone.
      assert.deepStrictEqual(sql.exec("SELECT * FROM meta"), [{ key: "deleted", value: 1 }]);
      assert.strictEqual(yield* store.schemaVersion(), storeMigrations.length);
      // Retrying is harmless.
      yield* store.deleteAll();
      assert.strictEqual(yield* store.schemaVersion(), storeMigrations.length);
      // Nothing can be written back, e.g. with an access token that outlived the account.
      const write = yield* Effect.flip(
        store.applyMutations([
          {
            entity: "health_characteristic",
            op: "upsert",
            id: "HKCharacteristicTypeIdentifierBloodType",
            row: { value: "aPositive" },
          },
        ]),
      );
      assert.strictEqual(write._tag, "AccountDeleted");
      const upload = yield* Effect.flip(
        store.receiveHealthBatch("00000000-0000-4000-8000-000000000001"),
      );
      assert.strictEqual(upload._tag, "AccountDeleted");
    }),
  );
});

describe("deleting a store", () => {
  it.effect("a wipe that fails is tried again by the next alarm", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      let failures = 1;
      const store = makeUserStore(sql, entities, {
        put: () => Effect.void,
        delete: () => (failures-- > 0 ? Effect.die("R2 is down") : Effect.void),
      });
      sql.exec("INSERT INTO meta (key, value) VALUES ('epoch', 2)");
      yield* store.deleteAll();
      yield* store.alarm();
      // Still marked for deleting, with the alarm set a minute later.
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), 60_000);
      assert.lengthOf(sql.exec("SELECT * FROM meta WHERE key = 'epoch'"), 1);
      // Deleting again meanwhile changes nothing.
      yield* store.deleteAll();
      yield* store.alarm();
      assert.deepStrictEqual(sql.exec("SELECT * FROM meta"), [{ key: "deleted", value: 1 }]);
    }),
  );
});

describe("the storage quota", () => {
  const bloodType = (value: string) =>
    ({
      entity: "health_characteristic",
      op: "upsert",
      id: "HKCharacteristicTypeIdentifierBloodType",
      row: { value },
    }) as const;
  const batchId = "00000000-0000-4000-8000-000000000001";

  const isFull = (error: { readonly _tag: string }) =>
    assert.strictEqual(error._tag, "StorageFull");

  it.effect("stops new uploads at the quota, but still applies accepted batches", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      yield* store.receiveHealthBatch(batchId);

      sql.setDatabaseSize(storageQuotaBytes);
      assert.deepInclude(
        yield* Effect.flip(store.checkHealthBatchUpload("00000000-0000-4000-8000-000000000002")),
        { _tag: "StorageFull", quotaBytes: storageQuotaBytes },
      );
      // A batch it already knows still answers with its status.
      assert.deepInclude(yield* store.checkHealthBatchUpload(batchId), { status: "queued" });
      // Batches accepted before the quota are still applied.
      yield* store.applyMutations([bloodType("aPositive")]);

      sql.setDatabaseSize(storageQuotaBytes - 1);
      assert.isNull(yield* store.checkHealthBatchUpload("00000000-0000-4000-8000-000000000002"));
    }),
  );

  it.effect("takes deletes but no new records at the hard limit", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      yield* store.applyMutations([bloodType("aPositive")]);

      sql.setDatabaseSize(storageHardLimitBytes);
      isFull(yield* Effect.flip(store.applyMutations([bloodType("bNegative")])));
      isFull(
        yield* Effect.flip(
          store.applyMutations([
            {
              entity: "health_characteristic",
              op: "delete",
              id: "HKCharacteristicTypeIdentifierSex",
            },
            bloodType("bNegative"),
          ]),
        ),
      );
      const deleted = yield* store.applyMutations([
        {
          entity: "health_characteristic",
          op: "delete",
          id: "HKCharacteristicTypeIdentifierBloodType",
        },
      ]);
      assert.strictEqual(deleted.appended, 1);
    }),
  );

  it("declares StorageFull, so it crosses RPC as itself", () => {
    assert.include(userStoreErrors, StorageFull);
  });

  it("reports the database's real size", () => {
    const sql = makeTestStoreSql();
    makeUserStore(sql);
    assert.isAbove(sql.databaseSize(), 0);
  });
});

describe("fromDurableObjectStorage", () => {
  it.effect("runs statements and transactions on workerd's storage", () =>
    Effect.gen(function* () {
      const calls: Array<string> = [];
      const sql = fromDurableObjectStorage({
        sql: {
          exec: (query, ...bindings) => {
            calls.push(`exec ${query} ${JSON.stringify(bindings)}`);
            return { toArray: () => [{ n: 1 }] };
          },
          databaseSize: 4096,
        },
        transactionSync: (body) => {
          calls.push("transactionSync");
          return body();
        },
        deleteAlarm: async () => {
          calls.push("deleteAlarm");
        },
        deleteAll: async () => {
          calls.push("deleteAll");
        },
        getAlarm: async () => {
          calls.push("getAlarm");
          return 7;
        },
        setAlarm: async (at) => {
          calls.push(`setAlarm ${at}`);
        },
      });
      assert.deepStrictEqual(sql.exec("SELECT ?", 1), [{ n: 1 }]);
      assert.strictEqual(sql.databaseSize(), 4096);
      sql.script("CREATE TABLE t (x);");
      assert.strictEqual(
        sql.transaction(() => "done"),
        "done",
      );
      yield* Effect.promise(() => sql.deleteAll());
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), 7);
      yield* Effect.promise(() => sql.setAlarm(9));
      assert.deepStrictEqual(calls, [
        "exec SELECT ? [1]",
        "exec CREATE TABLE t (x); []",
        "transactionSync",
        "deleteAlarm",
        "deleteAll",
        "getAlarm",
        "setAlarm 9",
      ]);
    }),
  );
});

/** Live connections, which these tests don't make. */
const noLive = () => Effect.die("No live connections in this test");

describe("UserStores", () => {
  const ada = "usr_000000000000000000000000ad" as UserId;
  const bob = "usr_000000000000000000000000b0" as UserId;

  it.effect("gives each user their own store, by name", () =>
    Effect.gen(function* () {
      const opened = new Map<string, { sql: StoreSql; store: UserStoreMethods }>();
      const stores = UserStores.fromNamespace({
        getByName: (name) => {
          const existing = opened.get(name);
          if (existing !== undefined) return { ...existing.store, fetch: noLive };
          const sql = makeTestStoreSql();
          const store = makeUserStore(sql);
          opened.set(name, { sql, store });
          return { ...store, fetch: noLive };
        },
      });

      yield* stores.forUser(ada).schemaVersion();
      opened.get(`user:${ada}`)?.sql.exec("INSERT INTO meta (key, value) VALUES ('epoch', '1')");
      yield* stores.forUser(bob).deleteAll();

      assert.deepStrictEqual([...opened.keys()], [`user:${ada}`, `user:${bob}`]);
      assert.deepStrictEqual(opened.get(`user:${ada}`)?.sql.exec("SELECT value FROM meta"), [
        { value: "1" },
      ]);
    }),
  );

  it.effect("reports a failed call as UserStoreUnavailable", () =>
    Effect.gen(function* () {
      const failing = {
        schemaVersion: () =>
          Effect.fail({
            _tag: "RpcCallError",
            method: "schemaVersion",
            cause: Object.assign(new Error("reset"), { retryable: true }),
          }),
      } as unknown as UserStoreMethods;
      const stores = UserStores.fromNamespace({
        getByName: () => ({ ...failing, fetch: noLive }),
      });
      const error = yield* Effect.flip(stores.forUser(ada).schemaVersion());
      assert.strictEqual(error._tag, "UserStoreUnavailable");
      assert.include(error.message, "reset");
    }),
  );

  it.effect("reports a store that threw as a defect, since retrying won't help", () =>
    Effect.gen(function* () {
      const failing = {
        schemaVersion: () =>
          Effect.fail({ _tag: "RpcCallError", method: "schemaVersion", cause: new Error("bug") }),
      } as unknown as UserStoreMethods;
      const stores = UserStores.fromNamespace({
        getByName: () => ({ ...failing, fetch: noLive }),
      });
      const exit = yield* Effect.exit(stores.forUser(ada).schemaVersion());
      assert.isTrue(Exit.hasDies(exit));
    }),
  );
});
