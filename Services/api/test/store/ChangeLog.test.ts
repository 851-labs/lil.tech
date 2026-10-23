import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import {
  applyMutations,
  readChanges,
  readHead,
  upsertGroupSize,
  writeBytes,
} from "../../src/store/ChangeLog.ts";
import type { Mutation } from "../../src/store/Changes.ts";
import { entities } from "../../src/store/Registry.ts";
import {
  Column,
  columnName,
  createEntityTable,
  defineEntity,
  type Entity,
} from "../../src/store/Entities.ts";
import type { SqlValue, StoreSql } from "../../src/store/StoreSql.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";
import { makeTestStore, testNote } from "./TestUserStores.ts";

const note = testNote;
const noteEntities = new Map([[note.name, note]]);

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

const makeStore = makeTestStore;

/** The log as it's served: each upsert with its record's current row (`readChanges`). */
const changes = (sql: StoreSql): Array<Record<string, unknown>> => {
  const page = readChanges(sql, noteEntities, 0, 100_000);
  if (!("changes" in page)) return assert.fail("compacted");
  return page.changes.map((change) => ({ ...change, row: "row" in change ? change.row : null }));
};

/** The rows changes were logged with, when they carry a copy (`copyRows`). */
const copies = (sql: StoreSql): Array<unknown> =>
  sql
    .exec("SELECT row FROM changes WHERE op = 'upsert' ORDER BY seq")
    .map((change) => JSON.parse(change["row"] as string) as unknown);

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
      // Each served right after it's applied: the log serves the record's current row.
      const rows: Array<unknown> = [];
      for (const mutation of [
        upsert("n1", fields({ score: 4 })),
        upsert("n1", { title: "Renamed" }),
        upsert("n1", { score: null }),
      ]) {
        yield* store.applyMutations([mutation]);
        rows.push(changes(sql).at(-1)?.["row"]);
      }
      assert.deepStrictEqual(rows, [
        { id: "n1", ...fields({ score: 4 }) },
        { id: "n1", ...fields({ score: 4, title: "Renamed" }) },
        { id: "n1", ...fields({ title: "Renamed" }) },
      ]);
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
        if (error._tag === "InvalidMutation") assert.strictEqual(error.index, 2);
      }
      assert.strictEqual(readHead(sql), 1);
      assert.deepStrictEqual(ids(sql), ["n1"]);
    }),
  );

  it("applies repeated IDs in one call in order, merging each into the last", () => {
    const { sql } = makeStore();
    // With copies, so each step's merged row can be seen.
    applyMutations(
      sql,
      noteEntities,
      [
        upsert("n1", fields({ score: 4 })),
        upsert("n2"),
        upsert("n1", { title: "Renamed" }),
        upsert("n1", { title: "Renamed" }),
        upsert("n1", { score: null }),
      ],
      0,
      true,
    );
    // The repeat changes nothing.
    assert.deepStrictEqual(copies(sql), [
      { id: "n1", ...fields({ score: 4 }) },
      { id: "n2", ...fields() },
      { id: "n1", ...fields({ score: 4, title: "Renamed" }) },
      { id: "n1", ...fields({ title: "Renamed" }) },
    ]);
  });

  it.effect("reports the first invalid mutation in a group of upserts", () =>
    Effect.gen(function* () {
      const { store } = makeStore();
      // A missing field (found against the stored row) before a field of the wrong type.
      const error = yield* Effect.flip(
        store.applyMutations([
          upsert("n1"),
          upsert("n2", { title: "No other fields" }),
          upsert("n3"),
          upsert("n4", fields({ pinned: "yes" })),
        ]),
      );
      assert.strictEqual(error._tag, "InvalidMutation");
      if (error._tag === "InvalidMutation") assert.strictEqual(error.index, 1);
    }),
  );

  it("applies an ID repeated right after a full group as a merge into the first", () => {
    const { sql } = makeStore();
    const entities = new Map([[note.name, note]]);
    const first = Array.from({ length: upsertGroupSize }, (_, n) =>
      upsert(`n${String(n).padStart(5, "0")}`),
    );
    const result = applyMutations(
      sql,
      entities,
      [...first, upsert("n00000", { title: "Renamed" }), upsert("n00001", { score: 3 })],
      0,
    );
    assert.deepStrictEqual(result, { head: upsertGroupSize + 2, appended: upsertGroupSize + 2 });
    assert.deepStrictEqual(
      changes(sql)
        .slice(-2)
        .map((change) => change["row"]),
      [
        { id: "n00000", ...fields({ title: "Renamed" }) },
        { id: "n00001", ...fields({ score: 3 }) },
      ],
    );
  });

  it("writes a group with big records in parts", () => {
    const { sql } = makeStore();
    const entities = new Map([[note.name, note]]);
    // About 10 KB each: a group of 100 is several parts of `writeBytes`.
    const big = ["x".repeat(10_000)];
    const count = 100;
    const result = applyMutations(
      sql,
      entities,
      Array.from({ length: count }, (_, n) => upsert(`n${n}`, fields({ tags: big }))),
      0,
    );
    assert.isAbove(count * 10_000, writeBytes * 2);
    assert.deepStrictEqual(result, { head: count, appended: count });
    assert.lengthOf(ids(sql), count);
    assert.deepStrictEqual(
      changes(sql).map((change) => change["seq"]),
      Array.from({ length: count }, (_, n) => n + 1),
    );
  });

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

describe("readChanges", () => {
  it("serves upserts logged without a copy with their records' current rows", () => {
    const { sql } = makeStore();
    // By default.
    const apply = (mutations: ReadonlyArray<Mutation>) =>
      applyMutations(sql, noteEntities, mutations, 0);
    apply([upsert("n1", fields({ score: 4 })), upsert("n2")]);
    apply([upsert("n1", { title: "Renamed" })]);
    apply([remove("n2")]);
    assert.deepStrictEqual(sql.exec("SELECT row, key FROM changes WHERE op = 'upsert'"), [
      { row: "", key: null },
      { row: "", key: null },
      { row: "", key: null },
    ]);
    const renamed = { id: "n1", ...fields({ score: 4, title: "Renamed" }) };
    assert.deepStrictEqual(readChanges(sql, noteEntities, 0, 10), {
      epoch: 1,
      changes: [
        { seq: 1, entity: "test_note", id: "n1", op: "upsert", row: renamed, at: 0 },
        // Deleted since: served as a delete, which ends the same way.
        { seq: 2, entity: "test_note", id: "n2", op: "delete", at: 0 },
        { seq: 3, entity: "test_note", id: "n1", op: "upsert", row: renamed, at: 0 },
        { seq: 4, entity: "test_note", id: "n2", op: "delete", at: 0 },
      ],
      next: 4,
      head: 4,
      hasMore: false,
    });
  });

  it("serves changes logged with and without copies together", () => {
    const { sql } = makeStore();
    applyMutations(sql, noteEntities, [upsert("n1", fields({ title: "Copied" }))], 0, true);
    applyMutations(sql, noteEntities, [upsert("n2")], 0, false);
    const page = readChanges(sql, noteEntities, 0, 10);
    if (!("changes" in page)) return assert.fail("compacted");
    assert.deepStrictEqual(
      page.changes.map((change) => ("row" in change ? change.row : null)),
      [
        { id: "n1", ...fields({ title: "Copied" }) },
        { id: "n2", ...fields() },
      ],
    );
  });

  it("stops a page before a copyless upsert of an entity it doesn't know", () => {
    const { sql } = makeStore();
    applyMutations(sql, noteEntities, [upsert("n1")], 0, true);
    applyMutations(sql, noteEntities, [upsert("n2"), upsert("n3")], 0, false);
    // A reader without the entity, as after a rollback: the copy is served, then it waits.
    const reader = new Map();
    const page = readChanges(sql, reader, 0, 10);
    if (!("changes" in page)) return assert.fail("compacted");
    assert.deepStrictEqual(
      page.changes.map((change) => change.seq),
      [1],
    );
    assert.deepInclude(page, { next: 1, head: 3, hasMore: true });
    assert.deepInclude(readChanges(sql, reader, 1, 10), { changes: [], next: 1, hasMore: true });
  });

  it("pages through the log", () => {
    const { sql } = makeStore();
    const entities = new Map([[note.name, note]]);
    applyMutations(sql, entities, [upsert("n1"), upsert("n2"), remove("n1")], 7);
    assert.deepStrictEqual(readChanges(sql, noteEntities, 0, 2), {
      epoch: 1,
      changes: [
        // n1 was deleted since: its upsert is served as a delete, which ends the same way.
        { seq: 1, entity: "test_note", id: "n1", op: "delete", at: 7 },
        {
          seq: 2,
          entity: "test_note",
          id: "n2",
          op: "upsert",
          row: { id: "n2", ...fields() },
          at: 7,
        },
      ],
      next: 2,
      head: 3,
      hasMore: true,
    });
    assert.deepStrictEqual(readChanges(sql, noteEntities, 2, 2), {
      epoch: 1,
      changes: [{ seq: 3, entity: "test_note", id: "n1", op: "delete", at: 7 }],
      next: 3,
      head: 3,
      hasMore: false,
    });
    assert.deepStrictEqual(readChanges(sql, noteEntities, 3, 2), {
      epoch: 1,
      changes: [],
      next: 3,
      head: 3,
      hasMore: false,
    });
  });

  it("returns an empty page for an empty log", () => {
    const { sql } = makeStore();
    assert.deepStrictEqual(readChanges(sql, noteEntities, 0, 1000), {
      epoch: 1,
      changes: [],
      next: 0,
      head: 0,
      hasMore: false,
    });
  });

  it("refuses a cursor older than the compaction horizon", () => {
    const { sql } = makeStore();
    applyMutations(sql, new Map([[note.name, note]]), [upsert("n1"), upsert("n2")], 0);
    sql.exec("DELETE FROM changes WHERE seq <= 1");
    sql.exec("INSERT INTO meta (key, value) VALUES ('horizon', 1)");
    assert.strictEqual(
      (readChanges(sql, noteEntities, 0, 10) as { _tag?: string })._tag,
      "ChangesCompacted",
    );
    assert.lengthOf(
      (readChanges(sql, noteEntities, 1, 10) as unknown as { changes: Array<unknown> }).changes,
      1,
    );
  });
});

describe("readChanges with an entities filter", () => {
  const card = defineEntity("test_card", { clientWritable: true, fields: { title: Column.text } });
  const both = new Map<string, Entity>([
    [note.name, note],
    [card.name, card],
  ]);
  const upsertCard = (id: string): Mutation => ({
    entity: "test_card",
    op: "upsert",
    id,
    row: { title: `Card ${id}` },
  });
  /** Notes at 1, 2, 4, 5, 7 and 8, cards at 3 and 6: 8 changes. */
  const makeMixed = () => {
    const { sql } = makeStore();
    sql.script(createEntityTable(card));
    applyMutations(sql, both, [upsert("n1"), upsert("n2"), upsertCard("c1")], 0);
    applyMutations(sql, both, [upsert("n3"), upsert("n4"), upsertCard("c2")], 0);
    applyMutations(sql, both, [upsert("n5"), remove("n5")], 0);
    return sql;
  };
  const read = (sql: StoreSql, after: number, limit: number, only: ReadonlyArray<string>) => {
    const page = readChanges(sql, both, after, limit, only);
    if (!("changes" in page)) return assert.fail("compacted");
    return { ...page, changes: page.changes.map((change) => [change.seq, change.id]) };
  };

  it("serves only those entities' changes, and moves next past the rest up to head", () => {
    const sql = makeMixed();
    assert.deepStrictEqual(read(sql, 0, 10, ["test_card"]), {
      epoch: 1,
      changes: [
        [3, "c1"],
        [6, "c2"],
      ],
      next: 8,
      head: 8,
      hasMore: false,
    });
    assert.deepInclude(read(sql, 3, 10, ["test_card"]), { changes: [[6, "c2"]], next: 8 });
    // Nothing after the cursor: still up to head.
    assert.deepInclude(read(sql, 6, 10, ["test_card"]), { changes: [], next: 8, hasMore: false });
    assert.deepInclude(read(sql, 8, 10, ["test_card"]), { changes: [], next: 8, hasMore: false });
    // An entity with no changes, or one the store doesn't know.
    assert.deepInclude(read(sql, 0, 10, ["nothing_here"]), { changes: [], next: 8 });
  });

  it("ends a full page at its last change", () => {
    const sql = makeMixed();
    // Full: there may be more, so next is the last change's seq.
    assert.deepInclude(read(sql, 0, 1, ["test_card"]), {
      changes: [[3, "c1"]],
      next: 3,
      head: 8,
      hasMore: true,
    });
    assert.deepInclude(read(sql, 3, 1, ["test_card"]), { changes: [[6, "c2"]], next: 6 });
    assert.deepInclude(read(sql, 6, 1, ["test_card"]), { changes: [], next: 8, hasMore: false });
  });

  it("merges several entities in log order, cut at the limit", () => {
    const sql = makeMixed();
    assert.deepInclude(read(sql, 1, 4, ["test_card", "test_note"]), {
      changes: [
        [2, "n2"],
        [3, "c1"],
        [4, "n3"],
        [5, "n4"],
      ],
      next: 5,
      hasMore: true,
    });
    // Repeated names count once, and an unfiltered read is unchanged.
    assert.deepInclude(read(sql, 5, 10, ["test_card", "test_card", "test_note"]), {
      changes: [
        [6, "c2"],
        [7, "n5"],
        [8, "n5"],
      ],
      next: 8,
    });
    const unfiltered = readChanges(sql, both, 0, 3);
    assert.deepInclude(unfiltered, { next: 3, hasMore: true });
  });

  it("stops before a copyless upsert of an entity it doesn't know, as without a filter", () => {
    const sql = makeMixed();
    // A reader without `test_card`, as after a rollback.
    const page = readChanges(sql, noteEntities, 0, 10, ["test_card"]);
    assert.deepInclude(page, { changes: [], next: 0, head: 8, hasMore: true });
  });

  it("refuses a cursor older than the compaction horizon", () => {
    const sql = makeMixed();
    sql.exec("DELETE FROM changes WHERE seq <= 2");
    sql.exec("INSERT INTO meta (key, value) VALUES ('horizon', 2)");
    assert.strictEqual(
      (readChanges(sql, both, 0, 10, ["test_card"]) as { _tag?: string })._tag,
      "ChangesCompacted",
    );
    assert.deepInclude(read(sql, 2, 10, ["test_card"]), { next: 8 });
  });

  it("reads each entity's seqs from the (entity, seq) index, then the page by seq", () => {
    const sql = makeMixed();
    const plan = (query: string, ...params: Array<SqlValue>) =>
      sql
        .exec(`EXPLAIN QUERY PLAN ${query}`, ...params)
        .map((step) => step["detail"] as string)
        .join("\n");
    const seqs = plan(
      "SELECT seq FROM changes WHERE entity = ? AND seq > ? ORDER BY seq LIMIT ?",
      "test_card",
      0,
      10,
    );
    assert.include(seqs, "COVERING INDEX changes_entity_seq");
    assert.notInclude(seqs, "TEMP B-TREE");
    const page = plan(
      "SELECT * FROM changes WHERE seq IN (SELECT value FROM json_each(?)) ORDER BY seq",
      "[3,6]",
    );
    assert.include(page, "INTEGER PRIMARY KEY");
  });
});

describe("entities", () => {
  it("maps fields to snake_case columns", () => {
    assert.strictEqual(columnName("startDate"), "start_date");
    assert.strictEqual(
      createEntityTable(note),
      'CREATE TABLE "test_note" (id TEXT PRIMARY KEY, "title" TEXT NOT NULL, "pinned" INTEGER NOT NULL, "score" REAL, "tags" TEXT NOT NULL, "created_at" INTEGER NOT NULL) STRICT;',
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
