import { gzipSync } from "node:zlib";
import { assert, describe, layer } from "@effect/vitest";
import { Clock, Effect, Layer } from "effect";
import { SqlClient, SqlError } from "effect/sql";
import { TestClock } from "effect/testing";
import type { DeviceId, UserId } from "../../src/core/Ids.ts";
import {
  failHealthBatch,
  healthBatchKey,
  storageFullFailure,
  healthChunkBytes,
  healthChunkSize,
  ingestHealthBatch,
  maxBatchLineLength,
  maxDecompressedBatchBytes,
} from "../../src/health/HealthIngestion.ts";
import { healthBatchesAtOnce, storageHardLimitBytes } from "../../src/store/UserStore.ts";
import { Users } from "../../src/core/Users.ts";
import { UserStores, UserStoreUnavailable } from "../../src/store/UserStores.ts";
import { TestCore } from "../core/TestCoreDatabase.ts";
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

/**
 * Runs `effect` with the user's store calling `applyMutations` through `wrap`, given the call's
 * number (from 1).
 */
const withApplyMutations = <A, E, R>(
  effect: Effect.Effect<A, E, R>,
  wrap: (
    call: number,
    apply: Effect.Effect<unknown, unknown>,
    mutations: ReadonlyArray<unknown>,
  ) => Effect.Effect<unknown, unknown>,
) =>
  Effect.gen(function* () {
    const stores = yield* UserStores;
    let calls = 0;
    const wrapped = UserStores.of({
      ...stores,
      forUser: (id) => {
        const store = stores.forUser(id);
        const applyMutations: typeof store.applyMutations = (mutations) =>
          wrap(++calls, store.applyMutations(mutations), mutations) as ReturnType<
            typeof store.applyMutations
          >;
        // The client is a proxy with no properties of its own, so it's wrapped in another.
        return new Proxy(store, {
          get: (target, method) =>
            method === "applyMutations" ? applyMutations : Reflect.get(target, method),
        });
      },
    });
    return yield* effect.pipe(Effect.provideService(UserStores, wrapped));
  });

const changesFor = (id: string) =>
  Effect.gen(function* () {
    const sql = (yield* TestStores).sqlFor(userId);
    return sql?.exec("SELECT seq, op FROM changes WHERE id = ? ORDER BY seq", id) ?? [];
  });

/** `userId` in the core database: ingestion drops batches for users it doesn't know. */
const KnownUser = Layer.effectDiscard(
  Effect.gen(function* () {
    const sql = yield* SqlClient.SqlClient;
    yield* sql`INSERT INTO users (id, display_name, created_at) VALUES (${userId}, NULL, 0)`;
  }),
).pipe(Layer.orDie, Layer.provideMerge(TestCore));

layer(Layer.mergeAll(TestUserStores, TestHealthIngestion, KnownUser))("ingestHealthBatch", (it) => {
  it.effect("drops a batch for an account deleted since it was queued", () =>
    Effect.gen(function* () {
      // A user the core database still knows (deleted between the lookup and the apply), whose
      // store is already gone.
      const user = yield* (yield* Users).create({ displayName: null });
      yield* (yield* UserStores).forUser(user.id).deleteAll();
      const batchId = "00000000-0000-4000-8000-0000000000ed";
      const files = (yield* TestHealthOutbox).files;
      files.set(healthBatchKey(user.id, batchId), batchFile([sample(91)]));
      yield* ingestHealthBatch({ userId: user.id, batchId });
      assert.isFalse(files.has(healthBatchKey(user.id, batchId)));
      assert.isUndefined(
        yield* (yield* UserStores)
          .forUser(user.id)
          .healthBatch(batchId)
          .pipe(Effect.catchTag("AccountDeleted", () => Effect.succeed(undefined))),
      );
    }),
  );

  it.effect("puts a batch back while its store applies as many as it takes at once", () =>
    Effect.gen(function* () {
      const store = (yield* UserStores).forUser(userId);
      // Others hold every place.
      const others = Array.from({ length: healthBatchesAtOnce }, () => newBatchId());
      for (const id of others) yield* store.beginHealthBatch(id, deviceId);

      const batchId = newBatchId();
      yield* store.receiveHealthBatch(batchId);
      const { files } = yield* TestHealthOutbox;
      files.set(healthBatchKey(userId, batchId), batchFile([sample(94)]));
      assert.deepStrictEqual(yield* ingestHealthBatch({ userId, batchId, deviceId }), {
        waitSeconds: 1,
      });
      // Nothing applied, the file kept for the next delivery, and the batch still queued.
      assert.isTrue(files.has(healthBatchKey(userId, batchId)));
      assert.lengthOf(yield* changesFor(uuid(94)), 0);
      assert.propertyVal(yield* store.healthBatch(batchId), "status", "queued");

      // Each time it's put back, its queued timeout starts over, so a backlog can't fail it.
      const stores = yield* TestStores;
      const updatedAt = () =>
        stores
          .sqlFor(userId)
          ?.exec("SELECT updated_at AS t FROM health_batches WHERE id = ?", batchId)[0]?.["t"];
      yield* TestClock.adjust("1 minute");
      assert.isDefined(yield* ingestHealthBatch({ userId, batchId, deviceId }));
      assert.strictEqual(updatedAt(), yield* Clock.currentTimeMillis);

      // Once a place frees up, it's applied.
      yield* store.releaseHealthBatch(others[0] ?? "");
      assert.isUndefined(yield* ingestHealthBatch({ userId, batchId, deviceId }));
      assert.propertyVal(yield* store.healthBatch(batchId), "status", "applied");
      for (const id of others.slice(1)) yield* store.releaseHealthBatch(id);
    }),
  );

  it.effect("starts batches in about the order they were received", () =>
    Effect.gen(function* () {
      const store = (yield* UserStores).forUser(userId);
      const { files } = yield* TestHealthOutbox;
      const others = Array.from({ length: healthBatchesAtOnce }, () => newBatchId());
      for (const id of others) yield* store.beginHealthBatch(id, deviceId);
      // Fourteen batches waiting, received in order.
      const waiting = Array.from({ length: 14 }, () => newBatchId());
      for (const [index, id] of waiting.entries()) {
        yield* store.receiveHealthBatch(id);
        files.set(healthBatchKey(userId, id), batchFile([sample(9_600 + index)]));
        yield* TestClock.adjust("1 millis");
      }
      const deliver = (index: number) =>
        ingestHealthBatch({ userId, batchId: waiting[index] ?? "", deviceId });

      // With a place free, the last one still waits for the thirteen before it, longer the more
      // there are, while the second one goes ahead: only the oldest few may start.
      yield* store.releaseHealthBatch(others[0] ?? "");
      assert.deepStrictEqual(yield* deliver(13), { waitSeconds: 4 });
      assert.isUndefined(yield* deliver(1));
      assert.propertyVal(yield* store.healthBatch(waiting[1] ?? ""), "status", "applied");
      assert.deepStrictEqual(yield* deliver(13), { waitSeconds: 3 });
      assert.isUndefined(yield* deliver(7));
      assert.isDefined(yield* deliver(13));

      // Batches whose messages were lost stop holding it back after a minute.
      yield* TestClock.adjust("61 seconds");
      assert.isUndefined(yield* deliver(13));

      for (const id of others.slice(1)) yield* store.releaseHealthBatch(id);
      for (const index of [0, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12]) {
        assert.isUndefined(yield* deliver(index));
      }
    }),
  );

  it.effect("carries on with a batch that began before, even while its store is busy", () =>
    Effect.gen(function* () {
      const store = (yield* UserStores).forUser(userId);
      // Began, then failed partway: its place is freed, and the queue retries it.
      const batchId = newBatchId();
      yield* store.receiveHealthBatch(batchId);
      yield* store.beginHealthBatch(batchId, deviceId);
      yield* store.releaseHealthBatch(batchId);
      const others = Array.from({ length: healthBatchesAtOnce }, () => newBatchId());
      for (const id of others) yield* store.beginHealthBatch(id, deviceId);

      (yield* TestHealthOutbox).files.set(healthBatchKey(userId, batchId), batchFile([sample(96)]));
      assert.isUndefined(yield* ingestHealthBatch({ userId, batchId, deviceId }));
      assert.propertyVal(yield* store.healthBatch(batchId), "status", "applied");
      for (const id of others) yield* store.releaseHealthBatch(id);
    }),
  );

  it.effect("frees a batch's place when it fails partway", () =>
    Effect.gen(function* () {
      const store = (yield* UserStores).forUser(userId);
      const lines = Array.from({ length: healthChunkSize + 1 }, (_, index) =>
        sample(30_000 + index),
      );
      // The store fails each batch's second chunk, more times than it has places.
      for (let attempt = 0; attempt <= healthBatchesAtOnce; attempt++) {
        const batchId = newBatchId();
        yield* store.receiveHealthBatch(batchId);
        const error = yield* withApplyMutations(
          Effect.flip(ingest(lines, batchId)),
          (call, apply) =>
            call === 2
              ? Effect.fail(new UserStoreUnavailable({ message: "The store restarted" }))
              : apply,
        );
        assert.strictEqual(error._tag, "UserStoreUnavailable");
      }
      const batchId = newBatchId();
      yield* store.receiveHealthBatch(batchId);
      const { batch } = yield* ingest([sample(97)], batchId);
      assert.propertyVal(batch, "status", "applied");
    }),
  );

  it.effect("drops a batch for a user the core database doesn't know", () =>
    Effect.gen(function* () {
      const stranger = "usr_000000000000000000000000zz" as UserId;
      const batchId = "00000000-0000-4000-8000-0000000000ee";
      const files = (yield* TestHealthOutbox).files;
      files.set(healthBatchKey(stranger, batchId), batchFile([sample(90)]));
      yield* ingestHealthBatch({ userId: stranger, batchId });
      assert.isFalse(files.has(healthBatchKey(stranger, batchId)));
      // No store was made for them.
      assert.isUndefined((yield* TestStores).sqlFor(stranger));
    }),
  );

  it.effect("failHealthBatch drops a batch for a user the core database doesn't know", () =>
    Effect.gen(function* () {
      const stranger = "usr_000000000000000000000000zy" as UserId;
      const batchId = "00000000-0000-4000-8000-0000000000ef";
      const files = (yield* TestHealthOutbox).files;
      files.set(healthBatchKey(stranger, batchId), batchFile([sample(92)]));
      yield* failHealthBatch({ userId: stranger, batchId }, "Applying the batch kept failing");
      assert.isFalse(files.has(healthBatchKey(stranger, batchId)));
      assert.isUndefined((yield* TestStores).sqlFor(stranger));
    }),
  );

  it.effect("applies a batch when the core database can't be asked about its user", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const unavailable = Users.of({
        ...users,
        findById: () =>
          Effect.fail(
            new SqlError.SqlError({
              reason: new SqlError.ConnectionError({ cause: new Error("D1 is down") }),
            }),
          ),
      });
      const { batch } = yield* ingest([sample(93)]).pipe(Effect.provideService(Users, unavailable));
      assert.deepInclude(batch, { status: "applied", applied: 1 });
    }),
  );

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

  it.effect("records the store's size once a batch is applied", () =>
    Effect.gen(function* () {
      const user = yield* (yield* Users).create({ displayName: null });
      const batchId = newBatchId();
      (yield* TestHealthOutbox).files.set(
        healthBatchKey(user.id, batchId),
        batchFile([sample(4200)]),
      );
      yield* ingestHealthBatch({ userId: user.id, batchId, deviceId });
      const size = (yield* TestStores).sqlFor(user.id)?.databaseSize();
      const [row] = yield* (yield* SqlClient.SqlClient)<{ storage_bytes: number }>`
        SELECT storage_bytes FROM users WHERE id = ${user.id}`;
      assert.isAbove(size ?? 0, 0);
      assert.strictEqual(row?.storage_bytes, size);
    }),
  );

  it.effect("drops a signed-out device's statistics, applying the rest of its batch", () =>
    Effect.gen(function* () {
      const retiredDevice = "dev_000000000000000000000000zz" as DeviceId;
      yield* ingest([sample(4300)]);
      yield* (yield* UserStores).forUser(userId).retireDevice(retiredDevice);
      const { batch } = yield* ingest(
        [statistic(1760400000000 + 30 * 60 * 1000 * 7, 5), sample(4301)],
        newBatchId(),
        retiredDevice,
      );
      assert.deepInclude(batch, {
        status: "applied",
        applied: 1,
        rejected: 1,
        rejectedLines: [{ line: 1, message: "The device signed out" }],
      });
    }),
  );

  it.effect("applies workouts with their activities, events and statistics", () =>
    Effect.gen(function* () {
      const id = uuid(4400);
      const workout = {
        entity: "health_workout",
        op: "upsert",
        id,
        row: {
          activityType: 37,
          startDate: 1760400000000,
          endDate: 1760401800000,
          duration: 1740,
          activities: [
            {
              id: uuid(4401),
              activityType: 37,
              startDate: 1760400000000,
              endDate: 1760401800000,
              duration: 1740,
              metadata: null,
              statistics: {},
            },
          ],
          events: [{ type: 1, startDate: 1760400600000, endDate: 1760400660000, metadata: null }],
          statistics: {
            HKQuantityTypeIdentifierHeartRate: {
              unit: "count/min",
              sum: null,
              average: 151,
              minimum: 98,
              maximum: 178,
              mostRecent: 160,
            },
          },
          sourceName: "Test Watch",
          sourceBundleId: "com.apple.health.00000000",
        },
      };
      const { batch } = yield* ingest([
        workout,
        { ...workout, id: "not-a-uuid" },
        { ...workout, id: uuid(4402), row: { ...workout.row, statistics: [] } },
      ]);
      assert.deepInclude(batch, { status: "applied", applied: 1, rejected: 2 });
      const sql = (yield* TestStores).sqlFor(userId);
      const [row] =
        sql?.exec("SELECT activity_type, events FROM health_workout WHERE id = ?", id) ?? [];
      assert.deepStrictEqual(row, {
        activity_type: 37,
        events: '[{"endDate":1760400660000,"metadata":null,"startDate":1760400600000,"type":1}]',
      });
    }),
  );

  it.effect("applies State of Mind logs and scored assessments", () =>
    Effect.gen(function* () {
      const provenance = { sourceName: "Test iPhone", sourceBundleId: "com.apple.health.00000000" };
      const mood = {
        entity: "health_state_of_mind",
        op: "upsert",
        id: uuid(4500),
        row: {
          startDate: 1760400000000,
          endDate: 1760400000000,
          kind: 2,
          valence: 0.4,
          valenceClassification: 5,
          labels: [10, 22],
          associations: [6],
          ...provenance,
        },
      };
      const gad7 = {
        entity: "health_scored_assessment",
        op: "upsert",
        id: uuid(4501),
        row: {
          type: "HKScoredAssessmentTypeIdentifierGAD7",
          startDate: 1760400000000,
          endDate: 1760400000000,
          score: 6,
          risk: 2,
          answers: [1, 1, 0, 1, 2, 0, 1],
          ...provenance,
        },
      };
      const { batch } = yield* ingest([
        mood,
        gad7,
        { ...gad7, id: uuid(4502), row: { ...gad7.row, answers: 3 } },
        { ...mood, id: uuid(4503), row: { ...mood.row, labels: ["happy"] } },
        { ...mood, id: uuid(4504), row: { ...mood.row, valence: 7 } },
      ]);
      assert.deepInclude(batch, { status: "applied", applied: 2, rejected: 3 });
      const sql = (yield* TestStores).sqlFor(userId);
      assert.deepStrictEqual(
        sql?.exec(
          "SELECT kind, valence, valence_classification, labels, associations FROM health_state_of_mind",
        ),
        [
          {
            kind: 2,
            valence: 0.4,
            valence_classification: 5,
            labels: "[10,22]",
            associations: "[6]",
          },
        ],
      );
      assert.deepStrictEqual(
        sql?.exec("SELECT type, score, risk, answers FROM health_scored_assessment"),
        [
          {
            type: "HKScoredAssessmentTypeIdentifierGAD7",
            score: 6,
            risk: 2,
            answers: "[1,1,0,1,2,0,1]",
          },
        ],
      );
    }),
  );

  it.effect("applies audiograms", () =>
    Effect.gen(function* () {
      const audiogram = {
        entity: "health_audiogram",
        op: "upsert",
        id: uuid(4600),
        row: {
          startDate: 1760400000000,
          endDate: 1760400000000,
          points: [
            {
              frequency: 1000,
              tests: [
                {
                  side: 0,
                  type: 0,
                  masked: false,
                  sensitivity: 20,
                  clampingLower: null,
                  clampingUpper: null,
                },
              ],
            },
          ],
          sourceName: "Test iPhone",
          sourceBundleId: "com.apple.health.00000000",
        },
      };
      const point = audiogram.row.points[0];
      const { batch } = yield* ingest([
        audiogram,
        { ...audiogram, id: uuid(4601), row: { ...audiogram.row, points: {} } },
        // Not ascending.
        { ...audiogram, id: uuid(4602), row: { ...audiogram.row, points: [point, point] } },
        // A test without its sensitivity.
        {
          ...audiogram,
          id: uuid(4603),
          row: { ...audiogram.row, points: [{ frequency: 500, tests: [{ side: 0 }] }] },
        },
      ]);
      assert.deepInclude(batch, { status: "applied", applied: 1, rejected: 3 });
      const sql = (yield* TestStores).sqlFor(userId);
      assert.deepStrictEqual(sql?.exec("SELECT points FROM health_audiogram"), [
        {
          points:
            '[{"frequency":1000,"tests":[{"clampingLower":null,"clampingUpper":null,"masked":false,"sensitivity":20,"side":0,"type":0}]}]',
        },
      ]);
    }),
  );

  it.effect("applies ECGs, which refer to their voltages blob", () =>
    Effect.gen(function* () {
      const ecg = {
        entity: "health_electrocardiogram",
        op: "upsert",
        id: uuid(4700),
        row: {
          startDate: 1760400000000,
          endDate: 1760400030000,
          classification: 1,
          symptomsStatus: 1,
          averageHeartRate: 62,
          samplingFrequency: 512,
          voltageCount: 15360,
          voltages: "a".repeat(64),
          sourceName: "Test Watch",
          sourceBundleId: "com.apple.NanoHeartRhythm.00000000",
        },
      };
      const { batch } = yield* ingest([
        ecg,
        // An inconclusive recording without measurements has no blob.
        {
          ...ecg,
          id: uuid(4701),
          row: {
            ...ecg.row,
            classification: 4,
            averageHeartRate: null,
            samplingFrequency: null,
            voltageCount: 0,
            voltages: null,
          },
        },
        { ...ecg, id: uuid(4702), row: { ...ecg.row, voltages: "not-a-hash" } },
        { ...ecg, id: uuid(4703), row: { ...ecg.row, voltages: "A".repeat(64) } },
        // The count and the blob must agree.
        { ...ecg, id: uuid(4704), row: { ...ecg.row, voltages: null } },
        { ...ecg, id: uuid(4705), row: { ...ecg.row, voltageCount: 0 } },
        { ...ecg, id: uuid(4706), row: { ...ecg.row, voltageCount: -1, voltages: null } },
      ]);
      assert.deepInclude(batch, { status: "applied", applied: 2, rejected: 5 });
      const sql = (yield* TestStores).sqlFor(userId);
      assert.deepStrictEqual(
        sql?.exec("SELECT voltage_count, voltages FROM health_electrocardiogram ORDER BY id"),
        [
          { voltage_count: 15360, voltages: "a".repeat(64) },
          { voltage_count: 0, voltages: null },
        ],
      );
    }),
  );

  it.effect("applies workout routes, which refer to their locations blob", () =>
    Effect.gen(function* () {
      const route = {
        entity: "health_workout_route",
        op: "upsert",
        id: uuid(4900),
        row: {
          startDate: 1760400000000,
          endDate: 1760403600000,
          workout: uuid(4950),
          locationCount: 3600,
          locations: "b".repeat(64),
          sourceName: "Test Watch",
          sourceBundleId: "com.apple.health.00000000",
        },
      };
      const { batch } = yield* ingest([
        route,
        {
          ...route,
          id: uuid(4901),
          row: { ...route.row, workout: null, locationCount: 0, locations: null },
        },
        { ...route, id: uuid(4904), row: { ...route.row, workout: "Not-A-UUID" } },
        { ...route, id: uuid(4902), row: { ...route.row, locations: null } },
        { ...route, id: uuid(4903), row: { ...route.row, locations: "not-a-hash" } },
      ]);
      assert.deepInclude(batch, { status: "applied", applied: 2, rejected: 3 });
      const sql = (yield* TestStores).sqlFor(userId);
      assert.deepStrictEqual(
        sql?.exec(
          "SELECT workout, location_count, locations FROM health_workout_route ORDER BY id",
        ),
        [
          { workout: uuid(4950), location_count: 3600, locations: "b".repeat(64) },
          { workout: null, location_count: 0, locations: null },
        ],
      );
    }),
  );

  it.effect("applies heartbeat series", () =>
    Effect.gen(function* () {
      const series = {
        entity: "health_heartbeat_series",
        op: "upsert",
        id: uuid(4800),
        row: {
          startDate: 1760400000000,
          endDate: 1760400060000,
          beats: [0, 0.82, 1.65, 3.31],
          gaps: [3],
          sourceName: "Test Watch",
          sourceBundleId: "com.apple.health.00000000",
        },
      };
      const { batch } = yield* ingest([
        series,
        { ...series, id: uuid(4801), row: { ...series.row, beats: [], gaps: [] } },
        // Not ascending, negative, or gaps outside the beats.
        { ...series, id: uuid(4802), row: { ...series.row, beats: [1, 0.5] } },
        { ...series, id: uuid(4803), row: { ...series.row, beats: [-1] } },
        { ...series, id: uuid(4804), row: { ...series.row, gaps: [4] } },
        { ...series, id: uuid(4805), row: { ...series.row, gaps: [2, 2] } },
      ]);
      assert.deepInclude(batch, { status: "applied", applied: 2, rejected: 4 });
      const sql = (yield* TestStores).sqlFor(userId);
      assert.deepStrictEqual(
        sql?.exec("SELECT beats, gaps FROM health_heartbeat_series ORDER BY id"),
        [
          { beats: "[0,0.82,1.65,3.31]", gaps: "[3]" },
          { beats: "[]", gaps: "[]" },
        ],
      );
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

  it.effect("fails a batch when the store reaches its hard limit, and deletes its file", () =>
    Effect.gen(function* () {
      yield* ingest([sample(4100)]);
      const sql = (yield* TestStores).sqlFor(userId);
      assert.isDefined(sql);
      sql.setDatabaseSize(storageHardLimitBytes);
      const { batchId, batch } = yield* ingest([sample(4101)]).pipe(
        Effect.ensuring(Effect.sync(() => sql.setDatabaseSize(null))),
      );
      assert.deepInclude(batch, { status: "failed", failure: storageFullFailure(0) });
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

  it.effect("applies chunks in order, reading the next while one is applied", () =>
    Effect.gen(function* () {
      const count = healthChunkSize * 2 + 3;
      const lines = Array.from({ length: count }, (_, index) => sample(40_000 + index));
      // The first sample again at the end, in the last chunk, with a new value.
      lines.push(sample(40_000, { value: 99 }));
      const sizes: Array<number> = [];
      const { batch } = yield* withApplyMutations(ingest(lines), (_, apply, mutations) =>
        Effect.sync(() => sizes.push(mutations.length)).pipe(Effect.andThen(apply)),
      );
      assert.deepInclude(batch, { status: "applied", lines: count + 1, applied: count + 1 });
      assert.deepStrictEqual(sizes, [healthChunkSize, healthChunkSize, 4]);
      assert.deepStrictEqual(
        (yield* changesFor(uuid(40_000))).map((change) => change["op"]),
        ["upsert", "upsert"],
      );
      const sql = (yield* TestStores).sqlFor(userId);
      assert.deepStrictEqual(
        sql?.exec("SELECT value FROM health_sample WHERE id = ?", uuid(40_000)),
        [{ value: 99 }],
      );
    }),
  );

  it.effect("ends a chunk at its size in bytes", () =>
    Effect.gen(function* () {
      // Lines of a fifth of a chunk's bytes and a little more, so five fill one.
      const metadata = { note: "x".repeat(Math.ceil(healthChunkBytes / 5)) };
      const lines = Array.from({ length: 6 }, (_, index) => sample(60_000 + index, { metadata }));
      const sizes: Array<number> = [];
      const { batch } = yield* withApplyMutations(ingest(lines), (_, apply, mutations) =>
        Effect.sync(() => sizes.push(mutations.length)).pipe(Effect.andThen(apply)),
      );
      assert.deepInclude(batch, { status: "applied", applied: 6 });
      assert.deepStrictEqual(sizes, [5, 1]);
    }),
  );

  it.effect("fails the batch when a chunk fails while the next is read", () =>
    Effect.gen(function* () {
      const lines = Array.from({ length: healthChunkSize * 2 + 1 }, (_, index) =>
        sample(20_000 + index),
      );
      const batchId = newBatchId();
      const error = yield* withApplyMutations(Effect.flip(ingest(lines, batchId)), (call, apply) =>
        call === 2
          ? Effect.fail(new UserStoreUnavailable({ message: "The store restarted" }))
          : apply,
      );
      assert.strictEqual(error._tag, "UserStoreUnavailable");
      // The first chunk stays applied; the queue retries the batch, which applies again.
      assert.strictEqual((yield* changesFor(uuid(20_000))).length, 1);
      assert.deepStrictEqual(yield* changesFor(uuid(20_000 + healthChunkSize)), []);
      assert.deepInclude(yield* (yield* UserStores).forUser(userId).healthBatch(batchId), {
        status: "applying",
      });
    }),
  );

  it.effect("refuses a device's records at once when it signs out during the batch", () =>
    Effect.gen(function* () {
      // A device of its own, so other tests' devices stay signed in.
      const device = "dev_000000000000000000000000sx" as DeviceId;
      const statistics = Array.from({ length: healthChunkSize * 2 }, (_, index) =>
        statistic(1760400000000 + (index + 1000) * 1_800_000, index),
      );
      const lines = [...statistics, sample(70_000)];
      const store = (yield* UserStores).forUser(userId);
      let calls = 0;
      const { batch } = yield* withApplyMutations(
        ingest(lines, newBatchId(), device),
        (call, apply) =>
          Effect.gen(function* () {
            calls = call;
            if (call === 1) yield* store.retireDevice(device);
            return yield* apply;
          }),
      );
      assert.deepInclude(batch, { status: "applied", applied: 1, rejected: statistics.length });
      // The chunk being applied and the one read meanwhile are refused a call each.
      assert.isAtMost(calls, 3);
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

layer(Layer.mergeAll(TestUserStores, TestHealthIngestion, KnownUser))(
  "health batch timeouts",
  (it) => {
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
  },
);

describe("ingestHealthBatch when the store is unavailable", () => {
  layer(Layer.mergeAll(TestHealthIngestion, KnownUser))((it) => {
    it.effect("fails, so the queue retries the batch", () =>
      Effect.gen(function* () {
        const unavailable = UserStores.fromNamespace({
          getByName: () =>
            ({
              beginHealthBatch: () =>
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
