import { Clock, Context, Effect, Layer, Option } from "effect";
import { HttpServerResponse } from "effect/http";
import type { UserId } from "../../src/core/Ids.ts";
import { Column, createEntityTable, defineEntity } from "../../src/store/Entities.ts";
import type { Mutation } from "../../src/store/Changes.ts";
import {
  type SnapshotFiles,
  type SnapshotPolicy,
  writeSnapshotStep,
} from "../../src/store/Snapshots.ts";
import type { StoreSql } from "../../src/store/StoreSql.ts";
import { type OpenedPart, type PartRange, SnapshotParts } from "../../src/sync/SnapshotParts.ts";
import { entities } from "../../src/store/Registry.ts";
import { sessionExpiresHeader } from "../../src/store/LiveNotices.ts";
import {
  makeUserStore,
  type UserStoreMethods,
  userStoreErrors,
} from "../../src/store/UserStore.ts";
import { UserStores, userStoreName } from "../../src/store/UserStores.ts";
import { makeTestStoreSql, type TestStoreSql } from "./TestStoreSql.ts";

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

/**
 * A store's methods with errors crossing as they do over Durable Object RPC: errors in
 * `userStoreErrors` as instances of their classes, any other as a plain object.
 */
const asOverRpc = (store: UserStoreMethods): UserStoreMethods =>
  Object.fromEntries(
    Object.entries(store).map(([name, method]) => [
      name,
      (...args: Array<unknown>) =>
        (method as (...args: Array<unknown>) => Effect.Effect<unknown, unknown>)(...args).pipe(
          Effect.mapError((error) =>
            userStoreErrors.some((type) => error instanceof type)
              ? error
              : (JSON.parse(JSON.stringify(error)) as unknown),
          ),
        ),
    ]),
  ) as UserStoreMethods;

/** `UserStores` over in-memory test stores, opened on first use like Durable Objects. */
export const makeTestUserStores = (files?: SnapshotFiles) => {
  const opened = new Map<string, { sql: TestStoreSql; store: UserStoreMethods }>();
  const stores = UserStores.fromNamespace({
    getByName: (name) => {
      const existing = opened.get(name) ?? makeTestStore(files);
      opened.set(name, existing);
      return {
        ...asOverRpc(existing.store),
        // A live connection can't be upgraded in tests; this answers with what the store got.
        fetch: (request) =>
          Effect.succeed(
            HttpServerResponse.jsonUnsafe({
              store: name,
              expiresAt: request.headers[sessionExpiresHeader],
            }),
          ),
      };
    },
  });
  return { stores, opened };
};

/** Direct access to the test stores' databases and snapshot files. */
export class TestStores extends Context.Service<
  TestStores,
  {
    readonly sqlFor: (userId: UserId) => TestStoreSql | undefined;
    readonly snapshotFiles: SnapshotFiles;
    readonly storedSnapshotFiles: Map<string, Uint8Array>;
  }
>()("test/TestStores") {}

/**
 * Opens a file in `stored`, or a range of it, as R2 does: a satisfiable range is served, one past
 * the end isn't.
 */
export const openStored =
  (stored: ReadonlyMap<string, Uint8Array>) =>
  (key: string, range: PartRange | undefined): Effect.Effect<Option.Option<OpenedPart>> =>
    Effect.sync(() =>
      Option.map(Option.fromNullishOr(stored.get(key)), (bytes) => {
        const size = bytes.length;
        const offset =
          range === undefined
            ? 0
            : "suffix" in range
              ? Math.max(0, size - range.suffix)
              : range.offset;
        const length =
          range !== undefined && "length" in range && range.length !== undefined
            ? Math.min(range.length, size - offset)
            : size - offset;
        const served = range !== undefined && offset < size;
        return {
          body: new Blob([
            (served ? bytes.slice(offset, offset + length) : bytes) as Uint8Array<ArrayBuffer>,
          ]).stream(),
          size,
          etag: `"${key}"`,
          ...(served ? { range: { offset, length } } : {}),
        };
      }),
    );

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
          open: openStored(stored),
        }),
      ),
    );
  }),
);

/** An upsert of a `test_note`. */
export const testNoteMutation = (id: string, title = `Note ${id}`): Mutation => ({
  entity: "test_note",
  op: "upsert",
  id,
  row: { title, pinned: false, score: null, tags: [], createdAt: 1 },
});

/**
 * Writes a whole snapshot of a test store, as its alarm would, running `between` after each part.
 * Fails if it doesn't finish.
 */
export const writeTestSnapshot = (
  sql: StoreSql,
  files: SnapshotFiles,
  policy: SnapshotPolicy,
  between: (step: number) => Effect.Effect<void, unknown> = () => Effect.void,
) =>
  Effect.gen(function* () {
    for (let step = 0; step < 1000; step++) {
      const now = yield* Clock.currentTimeMillis;
      const result = yield* writeSnapshotStep(sql, [...entities, testNote], files, now, policy);
      if (result !== "continue") return result;
      yield* between(step);
    }
    return yield* Effect.die("The snapshot never finished");
  });
