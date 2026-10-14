import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { applyMutations, readHead } from "../../src/store/ChangeLog.ts";
import {
  Column,
  columnName,
  createEntityTable,
  defineEntity,
  entities,
  type EntityRow,
} from "../../src/store/Entities.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";

const note = defineEntity("test_note", {
  clientWritable: true,
  fields: {
    title: Column.text,
    pinned: Column.boolean,
    score: Column.nullable(Column.real),
    tags: Column.json,
    createdAt: Column.integer,
  },
});

const row = (id: string, overrides: Partial<Record<string, unknown>> = {}) => ({
  id,
  title: `Note ${id}`,
  pinned: false,
  score: null,
  tags: ["a", { b: 1 }],
  createdAt: 1760400000000,
  ...overrides,
});

/** A store holding `test_note`, whose table a real entity's migration would create. */
const makeStore = () => {
  const sql = makeTestStoreSql();
  const store = makeUserStore(sql, [note]);
  sql.script(createEntityTable(note));
  return { sql, store };
};

const changes = (sql: ReturnType<typeof makeTestStoreSql>): Array<Record<string, unknown>> =>
  sql.exec("SELECT seq, entity, id, op, row, at FROM changes ORDER BY seq").map((change) => ({
    ...change,
    row: change["row"] === null ? null : (JSON.parse(change["row"] as string) as unknown),
  }));

describe("applyMutations", () => {
  it.effect("writes rows and appends their full rows to the log", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      const result = yield* store.applyMutations(
        "test_note",
        [row("n1"), row("n2", { pinned: true, score: 2.5 })],
        [],
      );
      assert.deepStrictEqual(result, { head: 2, appended: 2 });
      assert.deepStrictEqual(changes(sql), [
        { seq: 1, entity: "test_note", id: "n1", op: "upsert", row: row("n1"), at: 0 },
        {
          seq: 2,
          entity: "test_note",
          id: "n2",
          op: "upsert",
          row: row("n2", { pinned: true, score: 2.5 }),
          at: 0,
        },
      ]);
      assert.deepStrictEqual(sql.exec("SELECT id, pinned, tags, created_at FROM test_note"), [
        { id: "n1", pinned: 0, tags: '["a",{"b":1}]', created_at: 1760400000000 },
        { id: "n2", pinned: 1, tags: '["a",{"b":1}]', created_at: 1760400000000 },
      ]);
    }),
  );

  it.effect("has no gaps in seq under concurrent calls", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* Effect.all(
        Array.from({ length: 50 }, (_, call) =>
          store.applyMutations(
            "test_note",
            [row(`a${call}`), row(`b${call}`)],
            call % 5 === 4 ? [`a${call - 1}`] : [],
          ),
        ),
        { concurrency: "unbounded" },
      );
      const seqs = changes(sql).map((change) => change["seq"]);
      assert.deepStrictEqual(
        seqs,
        seqs.map((_, index) => index + 1),
      );
      assert.strictEqual(seqs.length, 110);
      assert.strictEqual(readHead(sql), 110);
    }),
  );

  it.effect("skips upserts that change nothing, so retries don't grow the log", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations("test_note", [row("n1")], []);
      assert.deepStrictEqual(yield* store.applyMutations("test_note", [row("n1")], []), {
        head: 1,
        appended: 0,
      });
      // The same record twice in one call: only the first changes anything.
      const renamed = row("n1", { title: "Renamed" });
      assert.deepStrictEqual(yield* store.applyMutations("test_note", [renamed, renamed], []), {
        head: 2,
        appended: 1,
      });
      assert.lengthOf(changes(sql), 2);
    }),
  );

  it.effect("records deletes as tombstones, and skips deletes of missing records", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations("test_note", [row("n1"), row("n2")], []);
      assert.deepStrictEqual(
        yield* store.applyMutations("test_note", [], ["n1", "missing", "n1"]),
        { head: 3, appended: 1 },
      );
      assert.deepStrictEqual(changes(sql)[2], {
        seq: 3,
        entity: "test_note",
        id: "n1",
        op: "delete",
        row: null,
        at: 0,
      });
      assert.deepStrictEqual(sql.exec("SELECT id FROM test_note"), [{ id: "n2" }]);
    }),
  );

  it("writes everything in a call or nothing", () => {
    const { sql } = makeStore();
    applyMutations(sql, note, [row("n1") as EntityRow], [], 0);
    // A row that skipped validation fails partway, at the NOT NULL `title`.
    const broken = { ...row("n3"), title: null } as unknown as EntityRow;
    assert.throws(() => applyMutations(sql, note, [row("n2") as EntityRow, broken], ["n1"], 0));
    assert.strictEqual(readHead(sql), 1);
    assert.deepStrictEqual(sql.exec("SELECT id FROM test_note"), [{ id: "n1" }]);
    assert.lengthOf(changes(sql), 1);
  });

  it("keeps counting from head after the newest changes are deleted", () => {
    const { sql } = makeStore();
    applyMutations(sql, note, [row("n1") as EntityRow, row("n2") as EntityRow], [], 0);
    sql.exec("DELETE FROM changes");
    const result = applyMutations(sql, note, [row("n3") as EntityRow], [], 0);
    assert.deepStrictEqual(result, { head: 3, appended: 1 });
  });

  it.effect("rejects unknown entities and invalid rows without writing anything", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      const unknown = yield* Effect.flip(store.applyMutations("nope", [row("n1")], []));
      assert.strictEqual(unknown._tag, "UnknownEntity");
      const invalid = yield* Effect.flip(
        store.applyMutations("test_note", [row("n1"), row("n2", { pinned: "yes" })], []),
      );
      assert.deepInclude(invalid, { _tag: "InvalidRow", entity: "test_note", index: 1 });
      assert.strictEqual(readHead(sql), 0);
      assert.deepStrictEqual(sql.exec("SELECT id FROM test_note"), []);
    }),
  );
});

describe("entities", () => {
  it("maps fields to snake_case columns", () => {
    assert.strictEqual(columnName("startDate"), "start_date");
    assert.strictEqual(
      createEntityTable(note),
      "CREATE TABLE test_note (id TEXT PRIMARY KEY, title TEXT NOT NULL, pinned INTEGER NOT NULL, score REAL, tags TEXT NOT NULL, created_at INTEGER NOT NULL) STRICT;",
    );
    assert.throws(() => defineEntity("Bad-Name", { clientWritable: false, fields: {} }));
  });

  it("each registered entity has a table that matches its fields after migrating", () => {
    const sql = makeTestStoreSql();
    makeUserStore(sql);
    assert.strictEqual(new Set(entities.map((entity) => entity.name)).size, entities.length);
    for (const entity of entities) {
      const expected = makeTestStoreSql();
      expected.script(createEntityTable(entity));
      const columns = (store: typeof sql) =>
        store
          .exec(`SELECT name, type, "notnull", pk FROM pragma_table_info('${entity.name}')`)
          .map((column) => JSON.stringify(column));
      assert.deepStrictEqual(columns(sql), columns(expected), entity.name);
    }
  });
});
