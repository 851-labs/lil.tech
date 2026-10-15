import { gzipSync } from "node:zlib";
import { assert, describe, layer } from "@effect/vitest";
import { Clock, Effect, Layer } from "effect";
import { TestClock } from "effect/testing";
import type { DeviceId, UserId } from "../../src/core/Ids.ts";
import {
  failHealthBatch,
  healthBatchKey,
  storageFullFailure,
  healthChunkSize,
  ingestHealthBatch,
  maxBatchLineLength,
  maxDecompressedBatchBytes,
} from "../../src/health/HealthIngestion.ts";
import { storageQuotaBytes } from "../../src/store/UserStore.ts";
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

const deviceId = "dev_000000000000000000000000ph" as DeviceId;

/** A statistic as the iPhone uploads it: keyed by type and bucket, without its device. */
const statistic = (bucketStart: number, sum: number) => ({
  entity: "health_statistic",
  op: "upsert",
  id: `HKQuantityTypeIdentifierStepCount@${bucketStart}`,
  row: { type: "HKQuantityTypeIdentifierStepCount", bucketStart, sum, unit: "count" },
});

/** Puts a batch file where the upload endpoint would, and ingests it. */
const ingest = (
  lines: ReadonlyArray<unknown>,
  batchId = newBatchId(),
  device: DeviceId | null = deviceId,
) =>
  Effect.gen(function* () {
    const { files } = yield* TestHealthOutbox;
    files.set(healthBatchKey(userId, batchId), batchFile(lines));
    yield* ingestHealthBatch(
      device === null ? { userId, batchId } : { userId, batchId, deviceId: device },
    );
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

  it.effect("stamps device-scoped records with the uploading device", () =>
    Effect.gen(function* () {
      const bucket = 1760400000000;
      const { batch } = yield* ingest([
        statistic(bucket, 1200),
        // A device field from the client is replaced.
        {
          ...statistic(bucket + 1800000, 300),
          row: { ...statistic(0, 300).row, bucketStart: bucket + 1800000, device: "dev_other" },
        },
        // `reportedAt` is the server's time, not the iPhone's.
        {
          entity: "health_statistics_device",
          op: "upsert",
          id: "self",
          row: { pairedWithWatch: true, reportedAt: 0 },
        },
      ]);
      assert.deepInclude(batch, { status: "applied", applied: 3, rejected: 0 });
      const sql = (yield* TestStores).sqlFor(userId);
      assert.deepStrictEqual(
        sql?.exec("SELECT id, device, bucket_start, sum FROM health_statistic ORDER BY id"),
        [
          {
            id: `${deviceId}/HKQuantityTypeIdentifierStepCount@${bucket}`,
            device: deviceId,
            bucket_start: bucket,
            sum: 1200,
          },
          {
            id: `${deviceId}/HKQuantityTypeIdentifierStepCount@${bucket + 1800000}`,
            device: deviceId,
            bucket_start: bucket + 1800000,
            sum: 300,
          },
        ],
      );
      const now = yield* Clock.currentTimeMillis;
      assert.deepStrictEqual(
        sql?.exec(
          "SELECT id, device, paired_with_watch, reported_at FROM health_statistics_device",
        ),
        [{ id: deviceId, device: deviceId, paired_with_watch: 1, reported_at: now }],
      );

      // Deletes are stamped too.
      yield* ingest([
        {
          entity: "health_statistic",
          op: "delete",
          id: `HKQuantityTypeIdentifierStepCount@${bucket}`,
        },
      ]);
      assert.strictEqual(sql?.exec("SELECT count(*) AS n FROM health_statistic")[0]?.["n"], 1);
    }),
  );

  it.effect("rejects statistics off a 30-minute boundary, or with a device in the ID", () =>
    Effect.gen(function* () {
      const { batch } = yield* ingest([
        statistic(1760400000000 + 60000, 5),
        {
          ...statistic(1760400000000, 5),
          id: `${deviceId}/HKQuantityTypeIdentifierStepCount@1760400000000`,
        },
      ]);
      assert.deepInclude(batch, { applied: 0, rejected: 2 });
      assert.deepStrictEqual(batch?.rejectedLines, [
        { line: 1, message: "bucketStart must be a multiple of 30 minutes" },
        {
          line: 2,
          message: `Invalid health_statistic ID ${deviceId}/HKQuantityTypeIdentifierStepCount@1760400000000`,
        },
      ]);
    }),
  );

  it.effect("rejects device-scoped lines from a batch without a device", () =>
    Effect.gen(function* () {
      const { batch } = yield* ingest(
        [statistic(1760400000000, 5), sample(90)],
        newBatchId(),
        null,
      );
      assert.deepInclude(batch, { applied: 1, rejected: 1 });
      assert.deepStrictEqual(batch?.rejectedLines, [
        { line: 1, message: "health_statistic needs the uploading device" },
      ]);
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

  it.effect("fails a batch when the store is full, and deletes its file", () =>
    Effect.gen(function* () {
      yield* ingest([sample(4100)]);
      const sql = (yield* TestStores).sqlFor(userId);
      assert.isDefined(sql);
      sql.setDatabaseSize(storageQuotaBytes);
      const { batchId, batch } = yield* ingest([sample(4101)]).pipe(
        Effect.ensuring(Effect.sync(() => sql.setDatabaseSize(null))),
      );
      assert.deepInclude(batch, { status: "failed", failure: storageFullFailure });
      assert.isFalse((yield* TestHealthOutbox).files.has(healthBatchKey(userId, batchId)));
      assert.deepStrictEqual(yield* changesFor(uuid(4101)), []);
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

  it.effect("fails a batch that decompresses to too much, without reading it all", () =>
    Effect.gen(function* () {
      const { files } = yield* TestHealthOutbox;
      const batchId = newBatchId();
      files.set(
        healthBatchKey(userId, batchId),
        new Uint8Array(gzipSync(Buffer.alloc(maxDecompressedBatchBytes + 1, " "))),
      );
      yield* ingestHealthBatch({ userId, batchId });
      assert.deepInclude(yield* (yield* UserStores).forUser(userId).healthBatch(batchId), {
        status: "failed",
        failure: "The batch is too large when decompressed",
      });
    }),
  );

  it.effect("rejects lines that are too long without keeping them", () =>
    Effect.gen(function* () {
      const { batch } = yield* ingest([sample(80), "x".repeat(maxBatchLineLength + 1), sample(81)]);
      assert.deepInclude(batch, { status: "applied", lines: 3, applied: 2, rejected: 1 });
      assert.strictEqual(batch?.rejectedLines?.[0]?.line, 2);
    }),
  );

  it.effect("a failed batch stays failed when it's delivered again", () =>
    Effect.gen(function* () {
      const { files } = yield* TestHealthOutbox;
      const batchId = newBatchId();
      files.set(healthBatchKey(userId, batchId), new TextEncoder().encode("plain text"));
      yield* ingestHealthBatch({ userId, batchId });
      files.set(healthBatchKey(userId, batchId), batchFile([sample(40)]));
      yield* ingestHealthBatch({ userId, batchId });
      assert.deepInclude(yield* (yield* UserStores).forUser(userId).healthBatch(batchId), {
        status: "failed",
      });
      assert.lengthOf(yield* changesFor(uuid(40)), 0);
    }),
  );

  it.effect("failHealthBatch leaves a batch another delivery already applied", () =>
    Effect.gen(function* () {
      const { batchId } = yield* ingest([sample(50)]);
      yield* failHealthBatch({ userId, batchId }, "Applying the batch kept failing");
      assert.deepInclude(yield* (yield* UserStores).forUser(userId).healthBatch(batchId), {
        status: "applied",
      });
    }),
  );

  it.effect("failHealthBatch marks a batch failed after its last attempt", () =>
    Effect.gen(function* () {
      const batchId = newBatchId();
      const store = (yield* UserStores).forUser(userId);
      const { files } = yield* TestHealthOutbox;
      files.set(healthBatchKey(userId, batchId), batchFile([sample(60)]));
      yield* store.receiveHealthBatch(batchId);
      yield* failHealthBatch({ userId, batchId }, "Applying the batch kept failing");
      assert.isFalse(files.has(healthBatchKey(userId, batchId)));
      assert.deepInclude(yield* store.healthBatch(batchId), {
        status: "failed",
        failure: "Applying the batch kept failing",
      });
    }),
  );
});

layer(Layer.mergeAll(TestUserStores, TestHealthIngestion))("health batch timeouts", (it) => {
  it.effect("a batch that stops moving is reported failed, and never applied later", () =>
    Effect.gen(function* () {
      const store = (yield* UserStores).forUser(userId);
      const { files } = yield* TestHealthOutbox;
      const batchId = newBatchId();
      files.set(healthBatchKey(userId, batchId), batchFile([sample(70)]));
      yield* store.receiveHealthBatch(batchId);
      yield* TestClock.adjust("23 hours");
      assert.deepInclude(yield* store.healthBatch(batchId), { status: "queued" });
      yield* TestClock.adjust("2 hours");
      assert.deepInclude(yield* store.healthBatch(batchId), {
        status: "failed",
        failure: "The batch timed out",
      });
      yield* ingestHealthBatch({ userId, batchId });
      assert.lengthOf(yield* changesFor(uuid(70)), 0);

      const applying = newBatchId();
      yield* store.saveHealthBatch({ id: applying, status: "applying", receivedAt: 0 });
      yield* TestClock.adjust("61 minutes");
      assert.deepInclude(yield* store.healthBatch(applying), { status: "failed" });
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
