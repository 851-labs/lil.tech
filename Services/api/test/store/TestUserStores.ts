import { Context, Effect, Layer } from "effect";
import type { UserId } from "../../src/core/Ids.ts";
import { Column, createEntityTable, defineEntity } from "../../src/store/Entities.ts";
import type { StoreSql } from "../../src/store/StoreSql.ts";
import { makeUserStore, type UserStoreMethods } from "../../src/store/UserStore.ts";
import { UserStores, userStoreName } from "../../src/store/UserStores.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";

/** An entity for tests, with every column type. */
export const testNote = defineEntity("test_note", {
  clientWritable: true,
  fields: {
    title: Column.text,
    pinned: Column.boolean,
    score: Column.nullable(Column.real),
    tags: Column.json,
    createdAt: Column.integer,
  },
});

/** A store holding `test_note`, whose table a real entity's migration would create. */
export const makeTestStore = () => {
  const sql = makeTestStoreSql();
  const store = makeUserStore(sql, [testNote]);
  sql.script(createEntityTable(testNote));
  return { sql, store };
};

/** `UserStores` over in-memory test stores, opened on first use like Durable Objects. */
export const makeTestUserStores = () => {
  const opened = new Map<string, { sql: StoreSql; store: UserStoreMethods }>();
  const stores = UserStores.fromNamespace({
    getByName: (name) => {
      const existing = opened.get(name) ?? makeTestStore();
      opened.set(name, existing);
      return existing.store;
    },
  });
  return { stores, opened };
};

/** Direct access to the test stores' databases, e.g. to simulate compaction. */
export class TestStores extends Context.Service<
  TestStores,
  { readonly sqlFor: (userId: UserId) => StoreSql | undefined }
>()("test/TestStores") {}

/** `UserStores` and `TestStores` over the same in-memory test stores. */
export const TestUserStores = Layer.unwrap(
  Effect.sync(() => {
    const { stores, opened } = makeTestUserStores();
    return Layer.mergeAll(
      Layer.succeed(UserStores, stores),
      Layer.succeed(TestStores, { sqlFor: (userId) => opened.get(userStoreName(userId))?.sql }),
    );
  }),
);
