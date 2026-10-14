import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { applyMutations, type Mutation, readHead } from "../../src/store/ChangeLog.ts";
import {
  Column,
  columnName,
  createEntityTable,
  defineEntity,
  entities,
} from "../../src/store/Entities.ts";
import type { StoreSql } from "../../src/store/StoreSql.ts";
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

const fields = (overrides: Record<string, unknown> = {}) => ({
  title: "Note",
  pinned: false,
  score: null,
  tags: ["a", { b: 1, c: 2 }],
  createdAt: 1760400000000,
  ...overrides,
});

const upsert = (id: string, row: Record<string, unknown> = fields()) =>
  ({ entity: "test_note", op: "upsert", id, row }) as Mutation;
const remove = (id: string): Mutation => ({ entity: "test_note", op: "delete", id });

/** A store holding `test_note`, whose table a real entity's migration would create. */
const makeStore = () => {
  const sql = makeTestStoreSql();
  const store = makeUserStore(sql, [note]);
  sql.script(createEntityTable(note));
  return { sql, store };
};

const changes = (sql: StoreSql): Array<Record<string, unknown>> =>
  sql.exec("SELECT seq, entity, id, op, row, at FROM changes ORDER BY seq").map((change) => ({
    ...change,
    row: change["row"] === null ? null : (JSON.parse(change["row"] as string) as unknown),
  }));

const ids = (sql: StoreSql) => sql.exec("SELECT id FROM test_note ORDER BY id").map((r) => r["id"]);

describe("applyMutations", () => {
  it.effect("writes records and appends their full rows to the log", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      const result = yield* store.applyMutations([
        upsert("n1"),
        upsert("n2", fields({ pinned: true, score: 2.5 })),
      ]);
      assert.deepStrictEqual(result, { head: 2, appended: 2 });
      assert.deepStrictEqual(changes(sql), [
        {
          seq: 1,
          entity: "test_note",
          id: "n1",
          op: "upsert",
          row: { id: "n1", ...fields() },
          at: 0,
        },
        {
          seq: 2,
          entity: "test_note",
          id: "n2",
          op: "upsert",
          row: { id: "n2", ...fields({ pinned: true, score: 2.5 }) },
          at: 0,
        },
      ]);
      assert.deepStrictEqual(sql.exec("SELECT id, pinned, tags, created_at FROM test_note"), [
        { id: "n1", pinned: 0, tags: '["a",{"b":1,"c":2}]', created_at: 1760400000000 },
        { id: "n2", pinned: 1, tags: '["a",{"b":1,"c":2}]', created_at: 1760400000000 },
      ]);
    }),
  );

  it.effect("has no gaps in seq under concurrent calls", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* Effect.all(
        Array.from({ length: 50 }, (_, call) =>
          store.applyMutations([
            upsert(`a${call}`),
            upsert(`b${call}`),
            ...(call % 5 === 4 ? [remove(`a${call - 1}`)] : []),
          ]),
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
      const { store } = makeStore();
      yield* store.applyMutations([upsert("n1")]);
      assert.deepStrictEqual(yield* store.applyMutations([upsert("n1")]), {
        head: 1,
        appended: 0,
      });
      // JSON object keys in another order are the same value.
      const reordered = fields({ tags: ["a", { c: 2, b: 1 }] });
      assert.deepStrictEqual(yield* store.applyMutations([upsert("n1", reordered)]), {
        head: 1,
        appended: 0,
      });
      // The same change twice in one call: only the first changes anything.
      const renamed = upsert("n1", fields({ title: "Renamed" }));
      assert.deepStrictEqual(yield* store.applyMutations([renamed, renamed]), {
        head: 2,
        appended: 1,
      });
    }),
  );

  it.effect("merges upserts: missing fields keep their values and null clears one", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations([upsert("n1", fields({ score: 4 }))]);
      yield* store.applyMutations([upsert("n1", { title: "Renamed" })]);
      yield* store.applyMutations([upsert("n1", { score: null })]);
      assert.deepStrictEqual(
        changes(sql).map((change) => change["row"]),
        [
          { id: "n1", ...fields({ score: 4 }) },
          { id: "n1", ...fields({ score: 4, title: "Renamed" }) },
          { id: "n1", ...fields({ title: "Renamed" }) },
        ],
      );
    }),
  );

  it.effect("records deletes as tombstones, and skips deletes of missing records", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations([upsert("n1"), upsert("n2")]);
      assert.deepStrictEqual(
        yield* store.applyMutations([remove("n1"), remove("missing"), remove("n1")]),
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
      assert.deepStrictEqual(ids(sql), ["n2"]);
    }),
  );

  it.effect("applies mutations in order", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations([upsert("n1")]);
      yield* store.applyMutations([remove("n1"), upsert("n1", fields({ title: "Again" }))]);
      assert.deepStrictEqual(ids(sql), ["n1"]);
      assert.deepStrictEqual(
        changes(sql).map((change) => change["op"]),
        ["upsert", "delete", "upsert"],
      );
    }),
  );

  it.effect("rejects a call with an invalid mutation without writing anything", () =>
    Effect.gen(function* () {
      const { sql, store } = makeStore();
      yield* store.applyMutations([upsert("n1")]);
      const invalid = [
        { entity: "nope", op: "delete", id: "x" } as Mutation,
        upsert("n2", fields({ pinned: "yes" })),
        upsert("n2", fields({ tags: null })),
        upsert("n2", { title: "No other fields" }),
      ];
      for (const mutation of invalid) {
        const error = yield* Effect.flip(
          store.applyMutations([upsert("n3"), remove("n1"), mutation]),
        );
        assert.strictEqual(error._tag, "InvalidMutation");
        assert.strictEqual(error.index, 2);
      }
      assert.strictEqual(readHead(sql), 1);
      assert.deepStrictEqual(ids(sql), ["n1"]);
    }),
  );

  it("rolls back everything when a statement fails partway", () => {
    const { sql } = makeStore();
    const entities = new Map([[note.name, note]]);
    applyMutations(sql, entities, [upsert("n1")], 0);
    sql.script(
      "CREATE TRIGGER fail BEFORE INSERT ON changes WHEN NEW.seq = 3 BEGIN SELECT RAISE(ABORT, 'boom'); END;",
    );
    assert.throws(() => applyMutations(sql, entities, [upsert("n2"), remove("n1")], 0), /boom/);
    assert.strictEqual(readHead(sql), 1);
    assert.deepStrictEqual(ids(sql), ["n1"]);
    assert.lengthOf(changes(sql), 1);
  });

  it("keeps counting from head after the newest changes are deleted", () => {
    const { sql } = makeStore();
    const entities = new Map([[note.name, note]]);
    applyMutations(sql, entities, [upsert("n1"), upsert("n2")], 0);
    sql.exec("DELETE FROM changes");
    assert.deepStrictEqual(applyMutations(sql, entities, [upsert("n3")], 0), {
      head: 3,
      appended: 1,
    });
  });
});

describe("entities", () => {
  it("maps fields to snake_case columns", () => {
    assert.strictEqual(columnName("startDate"), "start_date");
    assert.strictEqual(
      createEntityTable(note),
      "CREATE TABLE test_note (id TEXT PRIMARY KEY, title TEXT NOT NULL, pinned INTEGER NOT NULL, score REAL, tags TEXT NOT NULL, created_at INTEGER NOT NULL) STRICT;",
    );
  });

  it("refuses names that wouldn't map cleanly to tables and columns", () => {
    assert.throws(() => defineEntity("Bad-Name", { clientWritable: false, fields: {} }));
    for (const field of ["id", "HRV", "heartRateHRV", "start_date", "a b", "x'y"]) {
      assert.throws(
        () => defineEntity("ok", { clientWritable: false, fields: { [field]: Column.text } }),
        /Invalid field name/,
        field,
      );
    }
  });

  it("each registered entity has a table that matches its fields after migrating", () => {
    const sql = makeTestStoreSql();
    makeUserStore(sql);
    assert.strictEqual(new Set(entities.map((entity) => entity.name)).size, entities.length);
    for (const entity of entities) {
      const expected = makeTestStoreSql();
      expected.script(createEntityTable(entity));
      const columns = (store: StoreSql) =>
        store
          .exec(`SELECT name, type, "notnull", pk FROM pragma_table_info('${entity.name}')`)
          .map((column) => JSON.stringify(column));
      assert.deepStrictEqual(columns(sql), columns(expected), entity.name);
    }
  });
});
