import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { retireStep } from "../../src/store/RetiredDevices.ts";
import { entities } from "../../src/store/Registry.ts";
import { makeTestStore } from "./TestUserStores.ts";

// Synthetic data only (AGENTS.md).
const ada = "dev_000000000000000000000000a1";
const grace = "dev_000000000000000000000000b2";
const bucket = 1_760_400_000_000 - (1_760_400_000_000 % (30 * 60 * 1000));

const statistic = (device: string, n: number) => ({
  entity: "health_statistic",
  op: "upsert" as const,
  id: `${device}/HKQuantityTypeIdentifierStepCount@${bucket + n * 30 * 60 * 1000}`,
  row: {
    device,
    type: "HKQuantityTypeIdentifierStepCount",
    bucketStart: bucket + n * 30 * 60 * 1000,
    sum: n,
    unit: "count",
  },
});
const status = (device: string) => ({
  entity: "health_statistics_device",
  op: "upsert" as const,
  id: device,
  row: { device, pairedWithWatch: true, reportedAt: 1 },
});
const count = (sql: ReturnType<typeof makeTestStore>["sql"], device: string) =>
  [
    ...sql.exec('SELECT id FROM "health_statistic" WHERE device = ?', device),
    ...sql.exec('SELECT id FROM "health_statistics_device" WHERE device = ?', device),
  ].length;

describe("retiring a device", () => {
  it.effect("deletes its device-scoped records a chunk at a time, through the change log", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      yield* store.applyMutations([
        ...Array.from({ length: 5 }, (_, n) => statistic(ada, n)),
        status(ada),
        statistic(grace, 0),
        status(grace),
      ]);
      yield* store.retireDevice(ada);
      // Its alarm is due right away.
      assert.isNotNull(yield* Effect.promise(() => sql.getAlarm()));

      assert.strictEqual(retireStep(sql, entities, 2, 4), 4);
      assert.strictEqual(count(sql, ada), 2);
      assert.strictEqual(retireStep(sql, entities, 3, 4), 2);
      assert.strictEqual(count(sql, ada), 0);
      // Logged as deletions, so clients delete them too.
      const deletes = sql.exec("SELECT id FROM changes WHERE op = 'delete'");
      assert.lengthOf(deletes, 6);
      // The other device keeps its records.
      assert.strictEqual(count(sql, grace), 2);
      // Cleared once nothing's left.
      assert.strictEqual(retireStep(sql, entities, 4, 4), 0);
      assert.deepStrictEqual(sql.exec("SELECT device, cleared_at FROM retired_devices"), [
        { device: ada, cleared_at: 4 },
      ]);
    }),
  );

  it.effect("the alarm does the deleting", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      yield* store.applyMutations([statistic(ada, 0), status(ada)]);
      yield* store.retireDevice(ada);
      yield* store.alarm();
      assert.strictEqual(count(sql, ada), 0);
    }),
  );

  it.effect("refuses its records afterwards, e.g. from a batch still in the queue", () =>
    Effect.gen(function* () {
      const { store } = makeTestStore();
      yield* store.retireDevice(ada);
      const error = yield* Effect.flip(
        store.applyMutations([statistic(grace, 0), statistic(ada, 1)]),
      );
      assert.deepInclude(error, {
        _tag: "InvalidMutation",
        index: 1,
        message: "The device signed out",
      });
      // Retiring again is harmless.
      yield* store.retireDevice(ada);
    }),
  );
});
