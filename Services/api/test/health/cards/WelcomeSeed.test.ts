import { gunzipSync } from "node:zlib";
import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import seedJson from "../../../card-seed.json" with { type: "json" };
import { cardRowErrors } from "../../../src/health/cards/HealthCards.ts";
import { seededKey, seedWelcomeCards, welcomeSeed } from "../../../src/health/cards/WelcomeSeed.ts";
import type { Mutation } from "../../../src/store/Changes.ts";
import { createEntityTable } from "../../../src/store/Entities.ts";
import { entities } from "../../../src/store/Registry.ts";
import { latestSnapshot, snapshotPolicy } from "../../../src/store/Snapshots.ts";
import type { SnapshotFiles } from "../../../src/store/Snapshots.ts";
import type { StoreSql } from "../../../src/store/StoreSql.ts";
import {
  makeUserStore,
  startUserStore,
  type UserStoreMethods,
} from "../../../src/store/UserStore.ts";
import { makeTestStoreSql } from "../../store/TestStoreSql.ts";
import {
  makeTestSnapshotFiles,
  testNote,
  testNoteMutation,
  writeTestSnapshot,
} from "../../store/TestUserStores.ts";

// The welcome seed (851-3203, `docs/decisions/cards.md`, The welcome seed): the server seeds each
// store with Summary's six cards once, when it starts, through the change log, and never again.

const registry = [...entities, testNote];

/** Creates `test_note`'s table, which a real entity's migration would, unless it's there. */
const createTestNotes = (sql: StoreSql) => {
  if (sql.exec("SELECT 1 FROM sqlite_master WHERE name = 'test_note'").length === 0) {
    sql.script(createEntityTable(testNote));
  }
};

/** A store starting as the Worker starts one (`startUserStore`), over `sql`. */
const start = (sql: StoreSql, files?: SnapshotFiles) =>
  startUserStore(sql, registry, files).pipe(
    Effect.tap(() => Effect.sync(() => createTestNotes(sql))),
  );

/** A store as code from before the seed started it: migrated, never seeded. */
const startUnseeded = (sql: StoreSql) => {
  const store = makeUserStore(sql, registry);
  createTestNotes(sql);
  return store;
};

/** The seed's IDs, in Summary's order. */
const seedIds = welcomeSeed.map((card) => card.id);

const cards = (store: UserStoreMethods) =>
  store.readChanges(0, 1000, ["health_card"]).pipe(Effect.map((page) => page.changes));

/** The cards the store holds now, by ID, as rows. */
const storedCards = (sql: StoreSql) =>
  sql
    .exec(`SELECT id, position, seed FROM health_card ORDER BY position, id`)
    .map((row) => [row["id"], row["position"], row["seed"]]);

const ulid = "card_01JZ0000000000000000000001";

const userCard = (id: string, row: Record<string, unknown> = {}): Mutation => ({
  entity: "health_card",
  op: "upsert",
  id,
  row: {
    spec: welcomeSeed[1]!.spec,
    position: "a6",
    createdAt: 1,
    updatedAt: 1,
    seed: null,
    ...row,
  } as never,
});

describe("the welcome seed", () => {
  it("is Swift's six, each a valid row", () => {
    assert.deepStrictEqual(seedIds, [
      "card_seed_steps",
      "card_seed_heart_rate",
      "card_seed_active_energy",
      "card_seed_walking_running_distance",
      "card_seed_resting_heart_rate",
      "card_seed_weight",
    ]);
    assert.deepStrictEqual(
      welcomeSeed.map((card) => card.position),
      ["a0", "a1", "a2", "a3", "a4", "a5"],
    );
    for (const card of welcomeSeed) {
      const row = {
        spec: card.spec,
        position: card.position,
        createdAt: 1,
        updatedAt: 1,
        seed: card.seed,
      };
      assert.deepStrictEqual(cardRowErrors(card.id, row), [], card.id);
    }
  });

  it.effect("seeds a new account's store when it starts, through the change log", () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(1_800_000_000_000);
      const sql = makeTestStoreSql();
      const store = yield* start(sql);
      const changes = yield* cards(store);
      assert.deepStrictEqual(
        changes.map((change) => [change.seq, change.op, change.id]),
        seedIds.map((id, index) => [index + 1, "upsert", id]),
      );
      // Whole rows, as Swift defines them, written now.
      assert.deepStrictEqual(
        changes.map((change) => change.row),
        seedJson.cards.map((card) => ({
          id: card.id,
          spec: card.spec,
          position: card.position,
          createdAt: 1_800_000_000_000,
          updatedAt: 1_800_000_000_000,
          seed: card.seed,
        })),
      );
      assert.strictEqual(
        sql.exec("SELECT value FROM meta WHERE key = ?", seededKey)[0]?.["value"],
        1_800_000_000_000,
      );
    }),
  );

  it.effect("seeds an existing account's store once, after what it holds", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      // The store as code from before the seed left it, with a card and a note of its own.
      const before = startUnseeded(sql);
      yield* before.pushMutations("m1", [userCard(ulid)]);
      yield* before.applyMutations([testNoteMutation("n1")]);

      // It starts on the version that seeds: the six come after its own changes.
      const store = yield* start(sql);
      const page = yield* store.readChanges(0, 1000);
      assert.deepStrictEqual(
        page.changes.map((change) => change.id),
        [ulid, "n1", ...seedIds],
      );
      assert.deepStrictEqual(
        storedCards(sql).map(([id]) => id),
        [...seedIds, ulid],
      );

      // Every later start (a wake, a deploy) changes nothing.
      yield* start(sql);
      yield* start(sql);
      assert.strictEqual((yield* store.readChanges(0, 1000)).head, 8);
    }),
  );

  it.effect("never brings back a seed card that was deleted", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = yield* start(sql);
      yield* store.pushMutations("m1", [
        { entity: "health_card", op: "delete", id: "card_seed_steps" },
        { entity: "health_card", op: "delete", id: "card_seed_weight" },
      ]);
      // Seeding again, by a restart or directly, writes nothing.
      const restarted = yield* start(sql);
      assert.deepStrictEqual(seedWelcomeCards(sql, registry, 2), { _tag: "Skipped" });
      assert.deepStrictEqual(
        storedCards(sql).map(([id]) => id),
        seedIds.filter((id) => id !== "card_seed_steps" && id !== "card_seed_weight"),
      );
      assert.strictEqual((yield* restarted.readChanges(0, 1000)).head, 8);

      // Nor an account that deleted all six: its Summary stays empty.
      yield* restarted.pushMutations(
        "m2",
        seedIds.map((id) => ({ entity: "health_card", op: "delete", id })),
      );
      yield* start(sql);
      assert.deepStrictEqual(storedCards(sql), []);
    }),
  );

  it.effect("keeps the edits of an account that already has seed cards", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const before = startUnseeded(sql);
      const renamed = {
        ...(welcomeSeed[0]!.spec as Record<string, unknown>),
        display: { name: "Daily Steps", symbol: "flame.fill", color: "orange", unit: null },
      };
      yield* before.pushMutations("m1", [
        userCard("card_seed_steps", { spec: renamed, position: "a6", seed: "steps" }),
      ]);

      yield* start(sql);
      // The steps card is as the account left it, and the other five come with fixed IDs: never
      // a second steps card.
      assert.deepStrictEqual(storedCards(sql), [
        ["card_seed_heart_rate", "a1", "heart_rate"],
        ["card_seed_active_energy", "a2", "active_energy"],
        ["card_seed_walking_running_distance", "a3", "walking_running_distance"],
        ["card_seed_resting_heart_rate", "a4", "resting_heart_rate"],
        ["card_seed_weight", "a5", "weight"],
        ["card_seed_steps", "a6", "steps"],
      ]);
      const spec = sql.exec("SELECT spec FROM health_card WHERE id = 'card_seed_steps'")[0];
      assert.deepStrictEqual(JSON.parse(spec?.["spec"] as string).display.name, "Daily Steps");
    }),
  );

  it.effect("seeds once when the first requests arrive together", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      // Two starts racing over one store (a Durable Object starts once, under
      // blockConcurrencyWhile, but even so), each followed by a device's first pull and push.
      const [first, second] = yield* Effect.all([start(sql), start(sql)], {
        concurrency: "unbounded",
      });
      yield* Effect.all(
        [
          cards(first),
          cards(second),
          first.pushMutations("m1", [userCard(ulid)]),
          second.pushMutations("m2", [testNoteMutation("n1")]),
        ],
        { concurrency: "unbounded" },
      );
      const page = yield* first.readChanges(0, 1000);
      assert.deepStrictEqual(
        page.changes.slice(0, 6).map((change) => change.id),
        seedIds,
      );
      assert.strictEqual(page.head, 8);
      assert.lengthOf(storedCards(sql), 7);
    }),
  );

  it.effect("doesn't seed a deleted account's store", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const before = startUnseeded(sql);
      yield* before.deleteAll();
      yield* start(sql);
      assert.deepStrictEqual(storedCards(sql), []);
      assert.lengthOf(sql.exec("SELECT 1 FROM meta WHERE key = ?", seededKey), 0);
    }),
  );

  it.effect("is in the snapshot a new device bootstraps from", () =>
    Effect.gen(function* () {
      const { stored, files } = makeTestSnapshotFiles();
      const sql = makeTestStoreSql();
      const store = yield* start(sql, files);
      yield* store.pushMutations("m1", [
        { entity: "health_card", op: "delete", id: "card_seed_heart_rate" },
      ]);
      assert.strictEqual(
        yield* writeTestSnapshot(sql, files, { ...snapshotPolicy, minChanges: 1, quietPeriod: 0 }),
        "finished",
      );
      const parts =
        latestSnapshot(sql)?.entities.find((entity) => entity.entity === "health_card")?.parts ??
        [];
      const records = parts.flatMap((part) =>
        gunzipSync(stored.get(part.key) ?? new Uint8Array())
          .toString()
          .trim()
          .split("\n")
          .map((line) => JSON.parse(line) as Record<string, unknown>),
      );
      assert.sameMembers(
        records.map((record) => record["id"]),
        seedIds.filter((id) => id !== "card_seed_heart_rate"),
      );
    }),
  );

  it.effect("a store restored to before it seeded seeds the same six again, never more", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      yield* start(sql);
      // A point-in-time restore takes the flag back with the cards (they're one transaction).
      // Should a store ever lose the flag alone, seeding again writes the same IDs.
      sql.exec("DELETE FROM meta WHERE key = ?", seededKey);
      const restarted = yield* start(sql);
      assert.deepStrictEqual(
        storedCards(sql).map(([id]) => id),
        seedIds,
      );
      assert.strictEqual((yield* restarted.readChanges(0, 1000)).head, 6);
      assert.lengthOf(sql.exec("SELECT 1 FROM meta WHERE key = ?", seededKey), 1);
    }),
  );
});
