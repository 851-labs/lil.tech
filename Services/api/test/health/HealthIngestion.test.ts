import { assert, describe, layer } from "@effect/vitest";
import { Effect, Layer } from "effect";
import type { UserId } from "../../src/core/Ids.ts";
import {
  failHealthBatch,
  healthBatchKey,
  healthChunkSize,
  ingestHealthBatch,
} from "../../src/health/HealthIngestion.ts";
import { UserStores } from "../../src/store/UserStores.ts";
import { TestStores, TestUserStores } from "../store/TestUserStores.ts";
import { batchFile, TestHealthIngestion, TestHealthOutbox } from "./TestHealthIngestion.ts";

// Synthetic data only (AGENTS.md).
const userId = "usr_000000000000000000000000ad" as UserId;
let nextBatch = 0;
const newBatchId = () => `00000000-0000-4000-8000-${String(++nextBatch).padStart(12, "0")}`;
const uuid = (n: number) => `6f1c2a40-0000-4000-8000-${String(n).padStart(12, "0")}`;

const sample = (n: number, overrides: Record<string, unknown> = {}) => ({
  entity: "health_sample",
  op: "upsert",
  id: uuid(n),
  row: {
    type: "HKQuantityTypeIdentifierStepCount",
    startDate: 1760400000000 + n * 60000,
    endDate: 1760400060000 + n * 60000,
    value: n,
    unit: "count",
    sourceName: "Test iPhone",
    sourceBundleId: "com.apple.health.00000000",
    ...overrides,
  },
});

/** Puts a batch file where the upload endpoint would, and ingests it. */
const ingest = (lines: ReadonlyArray<unknown>, batchId = newBatchId()) =>
  Effect.gen(function* () {
    const { files } = yield* TestHealthOutbox;
    files.set(healthBatchKey(userId, batchId), batchFile(lines));
    yield* ingestHealthBatch({ userId, batchId });
    const batch = yield* (yield* UserStores).forUser(userId).healthBatch(batchId);
    return { batchId, batch };
  });

const changesFor = (id: string) =>
  Effect.gen(function* () {
    const sql = (yield* TestStores).sqlFor(userId);
    return sql?.exec("SELECT seq, op FROM changes WHERE id = ? ORDER BY seq", id) ?? [];
  });

layer(Layer.mergeAll(TestUserStores, TestHealthIngestion))("ingestHealthBatch", (it) => {
  it.effect("applies a batch, records its outcome, and deletes the file", () =>
    Effect.gen(function* () {
      const { batchId, batch } = yield* ingest([sample(1), sample(2), ""]);
      assert.deepInclude(batch, { status: "applied", lines: 2, applied: 2, rejected: 0 });
      assert.deepStrictEqual(batch?.rejectedLines, []);
      assert.isNumber(batch?.finishedAt);
      assert.lengthOf(yield* changesFor(uuid(1)), 1);
      assert.isFalse((yield* TestHealthOutbox).files.has(healthBatchKey(userId, batchId)));
    }),
  );

  it.effect("delivering the same batch again changes nothing", () =>
    Effect.gen(function* () {
      const { batchId } = yield* ingest([sample(10)]);
      // The file is gone, but an applied batch is skipped before it's read.
      yield* ingestHealthBatch({ userId, batchId });
      const again = yield* ingest([sample(10)]);
      assert.deepInclude(again.batch, { status: "applied", applied: 1 });
      assert.lengthOf(yield* changesFor(uuid(10)), 1);
    }),
  );

  it.effect("rejects malformed lines with details and applies the rest", () =>
    Effect.gen(function* () {
      const { batch } = yield* ingest([
        sample(20),
        "{not json",
        { entity: "test_note", op: "delete", id: "x" },
        { ...sample(21), id: uuid(21).toUpperCase() },
        sample(22, { value: "many" }),
        // Valid on its own, but a new record needs every required field.
        { entity: "health_sample", op: "upsert", id: uuid(23), row: { value: 1 } },
        { entity: "health_sample", op: "delete", id: uuid(24) },
        sample(25),
      ]);
      assert.deepInclude(batch, { status: "applied", lines: 8, applied: 3, rejected: 5 });
      assert.deepStrictEqual(
        batch?.rejectedLines?.map((rejected) => rejected.line),
        [2, 3, 4, 5, 6],
      );
      assert.include(batch?.rejectedLines?.[1]?.message, "Not a health entity");
      assert.include(batch?.rejectedLines?.[4]?.message, "Missing");
      assert.lengthOf(yield* changesFor(uuid(20)), 1);
      assert.lengthOf(yield* changesFor(uuid(25)), 1);
    }),
  );

  it.effect("applies deletes as tombstones", () =>
    Effect.gen(function* () {
      yield* ingest([sample(30)]);
      const { batch } = yield* ingest([{ entity: "health_sample", op: "delete", id: uuid(30) }]);
      assert.deepInclude(batch, { status: "applied", applied: 1 });
      assert.deepStrictEqual(
        (yield* changesFor(uuid(30))).map((change) => change["op"]),
        ["upsert", "delete"],
      );
    }),
  );

  it.effect("applies large batches in chunks", () =>
    Effect.gen(function* () {
      const count = healthChunkSize * 2 + 3;
      const lines = Array.from({ length: count }, (_, index) => sample(1000 + index));
      const { batch } = yield* ingest(lines);
      assert.deepInclude(batch, { status: "applied", lines: count, applied: count });
    }),
  );

  it.effect("fails a batch that isn't gzip, or whose file is gone", () =>
    Effect.gen(function* () {
      const { files } = yield* TestHealthOutbox;
      const stores = yield* UserStores;
      const unreadable = newBatchId();
      files.set(healthBatchKey(userId, unreadable), new TextEncoder().encode("plain text"));
      yield* ingestHealthBatch({ userId, batchId: unreadable });
      assert.deepInclude(yield* stores.forUser(userId).healthBatch(unreadable), {
        status: "failed",
      });

      const missing = newBatchId();
      yield* ingestHealthBatch({ userId, batchId: missing });
      const batch = yield* stores.forUser(userId).healthBatch(missing);
      assert.deepInclude(batch, { status: "failed", failure: "The batch file is missing" });
    }),
  );

  it.effect("failHealthBatch marks a batch failed after its last attempt", () =>
    Effect.gen(function* () {
      const batchId = newBatchId();
      const store = (yield* UserStores).forUser(userId);
      yield* store.receiveHealthBatch(batchId);
      yield* failHealthBatch({ userId, batchId }, "Applying the batch kept failing");
      assert.deepInclude(yield* store.healthBatch(batchId), {
        status: "failed",
        failure: "Applying the batch kept failing",
      });
    }),
  );
});

describe("ingestHealthBatch when the store is unavailable", () => {
  layer(TestHealthIngestion)((it) => {
    it.effect("fails, so the queue retries the batch", () =>
      Effect.gen(function* () {
        const unavailable = UserStores.fromNamespace({
          getByName: () =>
            ({
              healthBatch: () =>
                Effect.fail({
                  _tag: "RpcCallError",
                  cause: Object.assign(new Error("reset"), { retryable: true }),
                }),
            }) as never,
        });
        const error = yield* Effect.flip(
          ingestHealthBatch({ userId, batchId: newBatchId() }).pipe(
            Effect.provideService(UserStores, unavailable),
          ),
        );
        assert.strictEqual(error._tag, "UserStoreUnavailable");
      }),
    );
  });
});
