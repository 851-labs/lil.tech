import { gunzipSync } from "node:zlib";
import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { storeMaxCards } from "../../../src/health/cards/CardSpec.ts";
import { HealthCard } from "../../../src/health/cards/HealthCards.ts";
import type { Mutation } from "../../../src/store/Changes.ts";
import { latestSnapshot, snapshotPolicy } from "../../../src/store/Snapshots.ts";
import {
  makeTestSnapshotFiles,
  makeTestStore,
  testNoteMutation,
  writeTestSnapshot,
} from "../../store/TestUserStores.ts";

// The `health_card` entity in the store (851-3202, `docs/decisions/cards.md`): apps push whole
// rows, the last write of a card wins, the store checks each row and keeps at most 200, and cards
// reach other devices through the change feed and snapshots.

/** A canonical spec, named `name`. */
const spec = (name = "Heart Rate") => ({
  version: 1,
  display: { name, symbol: "heart.fill", color: "red", unit: null },
  series: [
    {
      id: "a",
      type: "HKQuantityTypeIdentifierHeartRate",
      aggregation: "avg",
      window: null,
      filter: null,
      label: null,
      hidden: false,
    },
  ],
  formulas: [],
  bucket: "auto",
  range: "W",
  chart: { style: "ranges", goal: null },
});

/** A card's ID, a ULID made from `n`. */
const cardId = (n: number) => `card_01JZ${String(n).padStart(22, "0")}`;

const upsert = (id: string, row: Record<string, unknown> = {}): Mutation => ({
  entity: "health_card",
  op: "upsert",
  id,
  row: { spec: spec(), position: "a0", createdAt: 1, updatedAt: 1, seed: null, ...row } as never,
});

const remove = (id: string): Mutation => ({ entity: "health_card", op: "delete", id });

const push = (store: ReturnType<typeof makeTestStore>["store"], mutations: Array<Mutation>) =>
  store.pushMutations(crypto.randomUUID(), mutations);

const cardChanges = (store: ReturnType<typeof makeTestStore>["store"]) =>
  store
    .readChanges(0, 1000, ["health_card"])
    .pipe(
      Effect.map((page) =>
        page.changes.map((change) => [change.op, change.id, change.row?.["position"] ?? null]),
      ),
    );

describe("health_card", () => {
  it.effect("takes whole rows from apps, and the last write of a card wins", () =>
    Effect.gen(function* () {
      const { store } = makeTestStore();
      const card = cardId(1);
      assert.deepStrictEqual(yield* push(store, [upsert(card)]), { seq: 1 });
      // A rename on one device and a move on another: each a whole row, the later one wins.
      yield* push(store, [upsert(card, { spec: spec("Pulse"), updatedAt: 2 })]);
      yield* push(store, [upsert(card, { position: "a1", updatedAt: 3 })]);
      const page = yield* store.readChanges(0, 100, ["health_card"]);
      assert.deepStrictEqual(page.changes.at(-1)?.row, {
        id: card,
        spec: spec(),
        position: "a1",
        createdAt: 1,
        updatedAt: 3,
        seed: null,
      });
      // Writing the same row again appends nothing.
      assert.deepStrictEqual(yield* push(store, [upsert(card, { position: "a1", updatedAt: 3 })]), {
        seq: 3,
      });
    }),
  );

  it.effect("refuses an upsert that leaves a field out, even of a card it has", () =>
    Effect.gen(function* () {
      const { store } = makeTestStore();
      const card = cardId(1);
      yield* push(store, [upsert(card)]);
      const { seed: _, ...withoutSeed } = {
        spec: spec(),
        position: "a1",
        createdAt: 1,
        updatedAt: 1,
        seed: null,
      };
      const error = yield* push(store, [
        upsert(cardId(2)),
        { entity: "health_card", op: "upsert", id: card, row: withoutSeed },
      ]).pipe(Effect.flip);
      assert.deepInclude(error, {
        _tag: "InvalidMutation",
        index: 1,
        message: "Missing seed: health_card upserts carry every field",
      });
      assert.deepStrictEqual(yield* cardChanges(store), [["upsert", card, "a0"]]);
    }),
  );

  it.effect("deletes a card, and an edit from a device that missed it brings it back", () =>
    Effect.gen(function* () {
      const { store } = makeTestStore();
      const card = cardId(1);
      yield* push(store, [upsert(card)]);
      yield* push(store, [remove(card)]);
      // Deleting what's gone appends nothing.
      assert.deepStrictEqual(yield* push(store, [remove(card)]), { seq: 2 });
      yield* push(store, [upsert(card, { position: "a2", updatedAt: 5 })]);
      assert.deepStrictEqual(yield* cardChanges(store), [
        // The first upsert is served as the card is now.
        ["upsert", card, "a2"],
        ["delete", card, null],
        ["upsert", card, "a2"],
      ]);
    }),
  );

  it.effect("refuses invalid rows with every error, a line each", () =>
    Effect.gen(function* () {
      const { store } = makeTestStore();
      const invalid = yield* push(store, [
        upsert(cardId(1), {
          spec: { ...spec(), display: { name: "Card" } },
          position: "a00",
          createdAt: 5,
          updatedAt: 4,
          seed: "steps",
        }),
      ]).pipe(Effect.flip);
      assert.deepInclude(invalid, {
        _tag: "InvalidMutation",
        index: 0,
        message: [
          `The card ${cardId(1)} has 4 errors:`,
          "- spec: The spec isn't in canonical form (a default left out, a type or activity by " +
            "name, or a name or label not trimmed): apps and tools write it canonicalized.",
          '- position: position "a00" isn\'t a fractional index: base-62 digits, starting with ' +
            "a letter that gives the length of its integer part.",
          "- updatedAt: updatedAt (4) can't be before createdAt (5).",
          "- seed: seed must be null: only seed cards (card_seed_…) have one.",
        ].join("\n"),
      });

      const unknownType = yield* push(store, [
        upsert(cardId(1), {
          spec: { ...spec(), series: [{ ...spec().series[0], type: "HeartRat" }] },
        }),
      ]).pipe(Effect.flip);
      assert.include(
        unknownType.message,
        '- spec.series[0].type: "HeartRat" isn\'t a type lil health knows. Did you mean Heart ' +
          "Rate (HKQuantityTypeIdentifierHeartRate)?",
      );
      const later = yield* push(store, [upsert(cardId(1), { spec: { version: 2 } })]).pipe(
        Effect.flip,
      );
      assert.include(later.message, "- spec.version: version 2 isn't supported.");
      const notJson = yield* push(store, [upsert(cardId(1), { spec: "{}" })]).pipe(Effect.flip);
      assert.include(notJson.message, "- spec: A card spec is a JSON object.");

      for (const id of ["card_01jz0000000000000000000001", "card_", "card_seed_Steps", "pin_1"]) {
        const badId = yield* push(store, [upsert(id)]).pipe(Effect.flip);
        assert.strictEqual(badId.message, `Invalid health_card ID ${id}`);
      }
      // A seed card's seed is its name.
      const wrongSeed = yield* push(store, [upsert("card_seed_steps", { seed: "weight" })]).pipe(
        Effect.flip,
      );
      assert.include(wrongSeed.message, '- seed: seed must be "steps", the seed card\'s name.');
      yield* push(store, [upsert("card_seed_steps", { seed: "steps" })]);
      assert.deepStrictEqual(yield* cardChanges(store), [["upsert", "card_seed_steps", "a0"]]);
    }),
  );

  it.effect("keeps a spec over the apps' 8 KB, and refuses one over 16 KB", () =>
    Effect.gen(function* () {
      const { store } = makeTestStore();
      /** Four series of heart rate, each filtered by ten long names of sources, and of devices. */
      const filtered = (deviceModels: boolean) => ({
        ...spec(),
        series: ["a", "b", "c", "d"].map((id) => {
          const names = Array.from({ length: 10 }, (_, n) => `${id}${n}`.padEnd(200, "x"));
          return {
            ...spec().series[0],
            id,
            filter: { sources: names, deviceModels: deviceModels ? names : null },
          };
        }),
      });
      yield* push(store, [upsert(cardId(1), { spec: filtered(false) })]);
      const tooLarge = yield* push(store, [upsert(cardId(2), { spec: filtered(true) })]).pipe(
        Effect.flip,
      );
      assert.match(tooLarge.message, /- spec: The spec is 1\d\.\d KB; the limit is 16 KB\.$/);
    }),
  );

  it.effect("keeps at most 200 cards, refusing the upsert that would make one more", () =>
    Effect.gen(function* () {
      const { store } = makeTestStore();
      const cards = Array.from({ length: storeMaxCards }, (_, n) => upsert(cardId(n)));
      yield* push(store, cards);
      const error = yield* push(store, [
        upsert(cardId(1), { updatedAt: 2 }),
        upsert(cardId(999)),
      ]).pipe(Effect.flip);
      assert.deepInclude(error, {
        _tag: "InvalidMutation",
        index: 1,
        message: "The store keeps at most 200 health_card records: delete one first",
      });
      // Nothing of the push applied.
      assert.lengthOf((yield* store.readChanges(0, 1000, ["health_card"])).changes, storeMaxCards);
      // Writing the cards it has is fine, and so is a new one once one's deleted, in the same push.
      yield* push(store, [
        upsert(cardId(1), { updatedAt: 2 }),
        remove(cardId(2)),
        upsert(cardId(999)),
      ]);
      yield* push(store, [remove(cardId(3))]);
      yield* push(store, [upsert(cardId(1000))]);
      const more = yield* push(store, [upsert(cardId(1001))]).pipe(Effect.flip);
      assert.deepInclude(more, { _tag: "InvalidMutation", index: 0 });
    }),
  );

  it.effect("reaches new devices in snapshots, and the change feed alone", () =>
    Effect.gen(function* () {
      const { stored, files } = makeTestSnapshotFiles();
      const { sql, store } = makeTestStore(files);
      yield* store.applyMutations([testNoteMutation("n1")]);
      yield* push(store, [
        upsert(cardId(1)),
        upsert("card_seed_steps", { seed: "steps", position: "a1" }),
      ]);

      // A phone pulling cards alone gets them, and moves past the note.
      const page = yield* store.readChanges(0, 100, ["health_card"]);
      assert.deepStrictEqual(
        page.changes.map((change) => change.id),
        [cardId(1), "card_seed_steps"],
      );
      assert.deepInclude(page, { next: 3, head: 3, hasMore: false });

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
      assert.deepStrictEqual(
        records.map((record) => [record["id"], record["position"], record["seed"]]),
        [
          [cardId(1), "a0", null],
          ["card_seed_steps", "a1", "steps"],
        ],
      );
      assert.deepStrictEqual(records[0]?.["spec"], spec());
    }),
  );

  it("is a whole-row entity apps write, with a limit", () => {
    assert.isTrue(HealthCard.clientWritable);
    assert.isTrue(HealthCard.wholeRows);
    assert.strictEqual(HealthCard.maxRecords, storeMaxCards);
  });
});
