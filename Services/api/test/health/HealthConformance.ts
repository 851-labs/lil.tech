import { readFileSync } from "node:fs";
import { assert } from "@effect/vitest";
import { Effect, Layer, Schema } from "effect";
import { SqlClient } from "effect/sql";
import { TestClock } from "effect/testing";
import type { DeviceId, UserId } from "../../src/core/Ids.ts";
import { healthBatchKey, ingestHealthBatch } from "../../src/health/HealthIngestion.ts";
import type { HealthBlobReader } from "../../src/health/tools/WorkoutRoutes.ts";
import { entities } from "../../src/store/Registry.ts";
import { UserStores } from "../../src/store/UserStores.ts";
import { TestCore } from "../core/TestCoreDatabase.ts";
import { TestStores, TestUserStores } from "../store/TestUserStores.ts";
import { batchFile, TestHealthIngestion, TestHealthOutbox } from "./TestHealthIngestion.ts";

// What the conformance harnesses share: the Health tools' (`tools/Conformance.test.ts`, 851-2841)
// and the cards' (`cards/CardConformance.test.ts`, 851-3198). A dataset is a synthetic account in
// upload form, each iPhone's batches, ingested as the server ingests uploads.

const Iso = Schema.String.annotate({ description: "An ISO 8601 time" });

export const millis = (iso: string) => Date.parse(iso);

const DatasetFile = Schema.Struct({
  /** Another dataset, relative to this one, whose batches come first. */
  extends: Schema.optionalKey(Schema.String),
  batches: Schema.Array(
    Schema.Struct({
      device: Schema.String,
      receivedAt: Iso,
      lines: Schema.Array(Schema.Unknown),
    }),
  ),
});
export type Batch = (typeof DatasetFile.Type)["batches"][number];

/** Reads a JSON file and decodes it with `schema`. */
export const readJson = <S extends Schema.Top & { readonly DecodingServices: never }>(
  url: URL,
  schema: S,
) => Schema.decodeUnknownSync(schema)(JSON.parse(readFileSync(url, "utf8")));

/**
 * Throws if a line sends a record of an entity with key fields (`Entity.key`) under other key
 * values than an earlier line with its ID (851-4181). A record's key fields never change: the
 * store would keep a second record, which it can't afford to look for, and a Mac, keyed by ID,
 * would replace the first, so the two sides' answers would differ. The Mac's harness checks the
 * datasets the same way (`ConformanceBatch.checkRecordKeys`, whose `keyFields` copy the entities'
 * keys).
 */
export const checkRecordKeys = (batches: ReadonlyArray<Batch>) => {
  const keyed = new Map(
    entities.filter((entity) => entity.key.length > 0).map((entity) => [entity.name, entity]),
  );
  const keys = new Map<string, string>();
  for (const line of batches.flatMap((batch) => batch.lines)) {
    const {
      entity: name,
      op,
      id,
      row,
    } = line as {
      entity?: unknown;
      op?: unknown;
      id?: unknown;
      row?: unknown;
    };
    const entity = typeof name === "string" ? keyed.get(name) : undefined;
    if (entity === undefined || op !== "upsert" || typeof id !== "string") continue;
    const fields = typeof row === "object" && row !== null ? (row as Record<string, unknown>) : {};
    const key = JSON.stringify(entity.key.map((field) => fields[field] ?? null));
    const earlier = keys.get(`${entity.name} ${id}`);
    if (earlier !== undefined && earlier !== key) {
      throw new Error(
        `${entity.name} ${id} is sent under two keys, ${earlier} and ${key}: give it another ID`,
      );
    }
    keys.set(`${entity.name} ${id}`, key);
  }
};

/** A dataset's batches, those of the one it extends first. */
export const readDataset = (url: URL): ReadonlyArray<Batch> => {
  const file = readJson(url, DatasetFile);
  const base = file.extends === undefined ? [] : readDataset(new URL(file.extends, url));
  return [...base, ...file.batches];
};

/**
 * The health blobs a dataset's rows refer to (`blobs.json`, base64 by SHA-256), as the store reads
 * them from R2 for the route tools (851-4164).
 */
export const readBlobs = (url: URL): HealthBlobReader => {
  const { blobs } = readJson(
    url,
    Schema.Struct({ blobs: Schema.Record(Schema.String, Schema.String) }),
  );
  return (sha256) =>
    Effect.succeed(
      blobs[sha256] === undefined ? null : new Uint8Array(Buffer.from(blobs[sha256], "base64")),
    );
};

// Synthetic data only (AGENTS.md).
export const conformanceUserId = "usr_000000000000000000000000c0" as UserId;

/** `conformanceUserId` in the core database: ingestion drops batches for users it doesn't know. */
const KnownUser = Layer.effectDiscard(
  Effect.gen(function* () {
    const sql = yield* SqlClient.SqlClient;
    yield* sql`INSERT INTO users (id, display_name, created_at) VALUES (${conformanceUserId}, NULL, 0)`;
  }),
).pipe(Layer.orDie, Layer.provideMerge(TestCore));

/**
 * A fresh store with `batches` ingested one by one, at each batch's time, then `after` run on it
 * (in the same stores, which it can reach through `TestStores` too), giving the store's SQL.
 */
export const storeWithBatches = <E>(
  batches: ReadonlyArray<Batch>,
  after: Effect.Effect<void, E, UserStores | TestStores> = Effect.void,
) =>
  Effect.gen(function* () {
    checkRecordKeys(batches);
    const { files } = yield* TestHealthOutbox;
    for (const [index, batch] of batches.entries()) {
      yield* TestClock.setTime(millis(batch.receivedAt));
      const batchId = `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`;
      files.set(healthBatchKey(conformanceUserId, batchId), batchFile(batch.lines));
      yield* ingestHealthBatch({
        userId: conformanceUserId,
        batchId,
        deviceId: batch.device as DeviceId,
      });
      const status = yield* (yield* UserStores).forUser(conformanceUserId).healthBatch(batchId);
      assert.deepInclude(status, { status: "applied", rejected: 0 }, `batch ${index + 1}`);
    }
    yield* after;
    const sql = (yield* TestStores).sqlFor(conformanceUserId);
    assert.isDefined(sql);
    return sql!;
  }).pipe(Effect.provide(Layer.mergeAll(TestUserStores, TestHealthIngestion, KnownUser)));

/** Whether two JSON values match, numbers within a relative 1e-9 (sums added in another order). */
export const matches = (actual: unknown, expected: unknown): boolean => {
  if (typeof actual === "number" && typeof expected === "number") {
    return Math.abs(actual - expected) <= 1e-9 * Math.max(1, Math.abs(expected));
  }
  if (Array.isArray(actual) && Array.isArray(expected)) {
    return (
      actual.length === expected.length && actual.every((value, i) => matches(value, expected[i]))
    );
  }
  if (
    typeof actual === "object" &&
    actual !== null &&
    typeof expected === "object" &&
    expected !== null &&
    !Array.isArray(actual) &&
    !Array.isArray(expected)
  ) {
    const keys = Object.keys(expected);
    return (
      Object.keys(actual).length === keys.length &&
      keys.every(
        (key) =>
          key in actual &&
          matches(
            (actual as Record<string, unknown>)[key],
            (expected as Record<string, unknown>)[key],
          ),
      )
    );
  }
  return actual === expected;
};
