import { Context, Effect, Layer, Option } from "effect";
import type { UserId } from "../../src/core/Ids.ts";
import { Column, createEntityTable, defineEntity } from "../../src/store/Entities.ts";
import type { SnapshotFiles } from "../../src/store/Snapshots.ts";
import type { StoreSql } from "../../src/store/StoreSql.ts";
import { SnapshotParts } from "../../src/sync/SnapshotParts.ts";
import { entities } from "../../src/store/Registry.ts";
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

/** A store holding the registered entities and `test_note`, whose table a real entity's migration
 * would create. */
export const makeTestStore = (files?: SnapshotFiles) => {
  const sql = makeTestStoreSql();
  const store = makeUserStore(sql, [...entities, testNote], files);
  sql.script(createEntityTable(testNote));
  return { sql, store };
};

/** Snapshot files in memory, shared by every test store, as R2 is in the Worker. */
export const makeTestSnapshotFiles = () => {
  const stored = new Map<string, Uint8Array>();
  const files: SnapshotFiles = {
    put: (key, bytes) => Effect.sync(() => void stored.set(key, bytes)),
    delete: (keys) => Effect.sync(() => keys.forEach((key) => stored.delete(key))),
  };
  return { stored, files };
};

/** `UserStores` over in-memory test stores, opened on first use like Durable Objects. */
export const makeTestUserStores = (files?: SnapshotFiles) => {
  const opened = new Map<string, { sql: StoreSql; store: UserStoreMethods }>();
  const stores = UserStores.fromNamespace({
    getByName: (name) => {
      const existing = opened.get(name) ?? makeTestStore(files);
      opened.set(name, existing);
      return existing.store;
    },
  });
  return { stores, opened };
};

/** Direct access to the test stores' databases and snapshot files. */
export class TestStores extends Context.Service<
  TestStores,
  {
    readonly sqlFor: (userId: UserId) => StoreSql | undefined;
    readonly snapshotFiles: SnapshotFiles;
    readonly storedSnapshotFiles: Map<string, Uint8Array>;
  }
>()("test/TestStores") {}

/**
 * `UserStores` and `TestStores` over the same in-memory test stores, and `SnapshotParts` reading
 * their snapshot files.
 */
export const TestUserStores = Layer.unwrap(
  Effect.sync(() => {
    const { stored, files } = makeTestSnapshotFiles();
    const { stores, opened } = makeTestUserStores(files);
    return Layer.mergeAll(
      Layer.succeed(UserStores, stores),
      Layer.succeed(TestStores, {
        sqlFor: (userId) => opened.get(userStoreName(userId))?.sql,
        snapshotFiles: files,
        storedSnapshotFiles: stored,
      }),
      Layer.succeed(
        SnapshotParts,
        SnapshotParts.of({
          open: (key) =>
            Effect.sync(() =>
              Option.map(Option.fromNullishOr(stored.get(key)), (bytes) => ({
                body: new Blob([bytes as Uint8Array<ArrayBuffer>]).stream(),
                size: bytes.length,
              })),
            ),
        }),
      ),
    );
  }),
);
