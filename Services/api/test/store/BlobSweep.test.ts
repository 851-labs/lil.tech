import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { blobGracePeriodMs, type BlobFiles } from "../../src/store/BlobSweep.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";

const prefix = "health-blobs/usr_test/";
const day = 24 * 60 * 60 * 1000;
const [kept, dropped, stray] = ["a", "b", "c"].map((letter) => letter.repeat(64)) as [
  string,
  string,
  string,
];

/** R2 in memory, with each object's upload time. */
const makeBlobFiles = () => {
  const objects = new Map<string, number>();
  const files: BlobFiles = {
    list: (listed) =>
      Effect.sync(() =>
        [...objects]
          .filter(([key]) => key.startsWith(listed))
          .map(([key, uploaded]) => ({ key, uploaded })),
      ),
    delete: (keys) => Effect.sync(() => keys.forEach((key) => objects.delete(key))),
  };
  return { objects, files };
};

/** A synthetic ECG referring to `voltages`. */
const ecg = (id: string, voltages: string) => ({
  entity: "health_electrocardiogram",
  op: "upsert" as const,
  id,
  row: {
    startDate: 1760400000000,
    endDate: 1760400030000,
    classification: 1,
    symptomsStatus: 1,
    averageHeartRate: 62,
    samplingFrequency: 512,
    voltageCount: 15360,
    voltages,
    sourceName: "Test Watch",
    sourceBundleId: "com.apple.NanoHeartRhythm.00000000",
  },
});
const ecgID = "6f1c2a40-0000-4000-8000-0000000000e1";

/** Uploads a blob as the API does: into R2, then recorded. */
const upload = (
  store: ReturnType<typeof makeUserStore>,
  objects: Map<string, number>,
  sha256: string,
) =>
  Effect.gen(function* () {
    objects.set(`${prefix}${sha256}`, yield* Effect.clockWith((clock) => clock.currentTimeMillis));
    yield* store.recordHealthBlob(sha256, 1000, prefix);
  });

/** Moves time on and runs the store's alarm, as the runtime would. */
const after = (store: ReturnType<typeof makeUserStore>, ms: number) =>
  TestClock.adjust(`${ms} millis`).pipe(Effect.andThen(store.alarm()));

describe("sweepBlobs", () => {
  it.effect("deletes blobs no record refers to once the grace period is over", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const { objects, files } = makeBlobFiles();
      const store = makeUserStore(sql, undefined, undefined, undefined, files);
      yield* upload(store, objects, kept);
      yield* upload(store, objects, dropped);
      yield* store.applyMutations([ecg(ecgID, kept)]);
      assert.strictEqual(yield* store.storageBytes(), sql.databaseSize() + 2000);
      // The first sweep is scheduled for a day after the first blob.
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), day);

      yield* after(store, day);
      const unreferenced = sql.exec(
        "SELECT sha256 FROM health_blobs WHERE unreferenced_since IS NOT NULL",
      );
      assert.deepStrictEqual(unreferenced, [{ sha256: dropped }]);
      // Still there during the grace period.
      yield* after(store, blobGracePeriodMs - day);
      assert.isTrue(objects.has(`${prefix}${dropped}`));

      yield* after(store, day);
      assert.deepStrictEqual([...objects.keys()], [`${prefix}${kept}`]);
      assert.deepStrictEqual(sql.exec("SELECT sha256 FROM health_blobs"), [{ sha256: kept }]);
      // It no longer counts towards the quota.
      assert.strictEqual(yield* store.storageBytes(), sql.databaseSize() + 1000);
    }),
  );

  it.effect("deletes a deleted record's blob, unless it's referred to or uploaded again", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const { objects, files } = makeBlobFiles();
      const store = makeUserStore(sql, undefined, undefined, undefined, files);
      yield* upload(store, objects, kept);
      yield* upload(store, objects, dropped);
      yield* store.applyMutations([
        ecg(ecgID, kept),
        ecg("6f1c2a40-0000-4000-8000-0000000000e2", dropped),
      ]);
      yield* store.applyMutations([
        { entity: "health_electrocardiogram", op: "delete", id: ecgID },
        {
          entity: "health_electrocardiogram",
          op: "delete",
          id: "6f1c2a40-0000-4000-8000-0000000000e2",
        },
      ]);
      yield* after(store, day);
      // Uploaded again, so a record is about to refer to it: kept, and swept later if not.
      assert.strictEqual(yield* store.checkHealthBlobUpload(kept), 1000);
      yield* after(store, blobGracePeriodMs);
      assert.deepStrictEqual([...objects.keys()], [`${prefix}${kept}`]);

      // A record refers to it again: it stays.
      yield* store.applyMutations([ecg(ecgID, kept)]);
      yield* after(store, blobGracePeriodMs + day);
      assert.deepStrictEqual([...objects.keys()], [`${prefix}${kept}`]);
    }),
  );

  it.effect("deletes objects it never recorded once they're as old", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const { objects, files } = makeBlobFiles();
      const store = makeUserStore(sql, undefined, undefined, undefined, files);
      yield* upload(store, objects, kept);
      yield* store.applyMutations([ecg(ecgID, kept)]);
      // An upload whose recording failed, and one still on its way.
      objects.set(`${prefix}${stray}`, 0);
      yield* after(store, blobGracePeriodMs);
      objects.set(`${prefix}${dropped}`, blobGracePeriodMs);
      yield* after(store, day);
      assert.deepStrictEqual(
        [...objects.keys()].toSorted(),
        [`${prefix}${kept}`, `${prefix}${dropped}`].toSorted(),
      );
    }),
  );

  it.effect("doesn't schedule sweeps for a store without blobs", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const store = makeUserStore(sql);
      yield* store.applyMutations([]);
      assert.isNull(yield* Effect.promise(() => sql.getAlarm()));
    }),
  );
});
