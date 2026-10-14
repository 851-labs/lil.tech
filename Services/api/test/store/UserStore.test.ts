import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import type { UserId } from "../../src/core/Ids.ts";
import { migrate, type StoreMigration, storeMigrations } from "../../src/store/Migrations.ts";
import { makeUserStore, type UserStoreMethods } from "../../src/store/UserStore.ts";
import { UserStores } from "../../src/store/UserStores.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";

const tables = (sql: ReturnType<typeof makeTestStoreSql>) =>
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

  it("numbers the store's migrations from 1 without gaps", () => {
    assert.deepStrictEqual(
      storeMigrations.map((migration) => migration.version),
      storeMigrations.map((_, index) => index + 1),
    );
  });
});

describe("makeUserStore", () => {
  it.effect("migrates on first use", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      assert.notInclude(tables(sql), "meta");
      assert.strictEqual(yield* store.schemaVersion(), storeMigrations.length);
      assert.include(tables(sql), "meta");
    }),
  );

  it.effect("deleteAll empties the store, which starts over fresh when used again", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      yield* store.schemaVersion();
      sql.exec("INSERT INTO meta (key, value) VALUES ('epoch', '3')");
      yield* store.deleteAll();
      assert.deepStrictEqual(tables(sql), []);
      assert.strictEqual(yield* store.schemaVersion(), storeMigrations.length);
      assert.deepStrictEqual(sql.exec("SELECT * FROM meta"), []);
    }),
  );
});

describe("UserStores", () => {
  it.effect("gives each user their own store, by name", () =>
    Effect.gen(function* () {
      const opened = new Map<string, ReturnType<typeof makeTestStoreSql>>();
      const stores = UserStores.fromNamespace({
        getByName: (name): UserStoreMethods => {
          const sql = opened.get(name) ?? makeTestStoreSql();
          opened.set(name, sql);
          return makeUserStore(sql);
        },
      });
      const ada = "usr_000000000000000000000000ad" as UserId;
      const bob = "usr_000000000000000000000000b0" as UserId;

      yield* stores.forUser(ada).schemaVersion();
      opened.get(`user:${ada}`)?.exec("INSERT INTO meta (key, value) VALUES ('epoch', '1')");
      yield* stores.forUser(bob).schemaVersion();
      yield* stores.forUser(bob).deleteAll();

      assert.deepStrictEqual([...opened.keys()], [`user:${ada}`, `user:${bob}`]);
      assert.deepStrictEqual(opened.get(`user:${ada}`)?.exec("SELECT value FROM meta"), [
        { value: "1" },
      ]);
    }),
  );
});
