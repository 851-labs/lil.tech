import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import type { UserId } from "../../src/core/Ids.ts";
import { migrate, type StoreMigration, storeMigrations } from "../../src/store/Migrations.ts";
import { fromDurableObjectStorage, type StoreSql } from "../../src/store/StoreSql.ts";
import { makeUserStore, type UserStoreMethods } from "../../src/store/UserStore.ts";
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

  it.effect("deleteAll empties the store, leaving it at the latest schema", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      sql.exec("INSERT INTO meta (key, value) VALUES ('epoch', '3')");
      yield* store.deleteAll();
      assert.deepStrictEqual(sql.exec("SELECT * FROM meta"), []);
      assert.strictEqual(yield* store.schemaVersion(), storeMigrations.length);
      // Retrying is harmless.
      yield* store.deleteAll();
      assert.strictEqual(yield* store.schemaVersion(), storeMigrations.length);
    }),
  );
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
      });
      assert.deepStrictEqual(sql.exec("SELECT ?", 1), [{ n: 1 }]);
      sql.script("CREATE TABLE t (x);");
      assert.strictEqual(
        sql.transaction(() => "done"),
        "done",
      );
      yield* Effect.promise(() => sql.deleteAll());
      assert.deepStrictEqual(calls, [
        "exec SELECT ? [1]",
        "exec CREATE TABLE t (x); []",
        "transactionSync",
        "deleteAlarm",
        "deleteAll",
      ]);
    }),
  );
});

describe("UserStores", () => {
  const ada = "usr_000000000000000000000000ad" as UserId;
  const bob = "usr_000000000000000000000000b0" as UserId;

  it.effect("gives each user their own store, by name", () =>
    Effect.gen(function* () {
      const opened = new Map<string, { sql: StoreSql; store: UserStoreMethods }>();
      const stores = UserStores.fromNamespace({
        getByName: (name) => {
          const existing = opened.get(name);
          if (existing !== undefined) return existing.store;
          const sql = makeTestStoreSql();
          const store = makeUserStore(sql);
          opened.set(name, { sql, store });
          return store;
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
          Effect.fail({ _tag: "RpcCallError", method: "schemaVersion", cause: "reset" }),
      } as unknown as UserStoreMethods;
      const stores = UserStores.fromNamespace({ getByName: () => failing });
      const error = yield* Effect.flip(stores.forUser(ada).schemaVersion());
      assert.strictEqual(error._tag, "UserStoreUnavailable");
      assert.include(error.message, "reset");
    }),
  );
});
