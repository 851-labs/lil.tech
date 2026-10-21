import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { assert, describe, it, layer } from "@effect/vitest";
import { Effect, Layer } from "effect";
import { SqlClient } from "effect/sql";
import type { DeviceId, UserId } from "../src/core/Ids.ts";
import { healthBatchKey, ingestHealthBatch } from "../src/health/HealthIngestion.ts";
import { UserStores } from "../src/store/UserStores.ts";
import {
  checkNotProd,
  formatTable,
  parseOptions,
  percentile,
  retryDelay,
} from "../scripts/bench-sync.ts";
import {
  fileRecords,
  kindCounts,
  kinds,
  provenanceRecord,
  sortedJson,
  syntheticBatches,
} from "../scripts/synthetic-health.ts";
import { TestCore } from "./core/TestCoreDatabase.ts";
import { TestHealthIngestion, TestHealthOutbox } from "./health/TestHealthIngestion.ts";
import { TestStores, TestUserStores } from "./store/TestUserStores.ts";

// Synthetic data only (AGENTS.md).
const options = { records: 30_000, seed: 7, end: Date.UTC(2026, 9, 1), run: "test-run" };
const parse = (text: string) =>
  text.split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);

describe("syntheticBatches", () => {
  const files = [...syntheticBatches(options)];

  it("makes the records asked for, in files of at most 5,000", () => {
    assert.strictEqual(
      files.reduce((sum, file) => sum + file.records, 0),
      30_000,
    );
    for (const file of files) assert.isAtMost(file.records, fileRecords);
    // 10,000-record pages, each cut in two, and each kind's last page smaller.
    assert.strictEqual(files[0]?.records, 5000);
  });

  it("writes each provenance once per file, before the records that refer to it", () => {
    for (const file of files) {
      const seen = new Set<string>();
      let records = 0;
      for (const line of parse(file.text)) {
        const row = line["row"] as Record<string, unknown>;
        if (line["entity"] === "health_provenance") {
          assert.isFalse(seen.has(line["id"] as string));
          seen.add(line["id"] as string);
          continue;
        }
        records++;
        if (row["provenance"] !== undefined) {
          assert.isTrue(seen.has(row["provenance"] as string));
          assert.isNull(row["sourceRevision"]);
          assert.isNull(row["device"]);
        }
      }
      assert.strictEqual(records, file.records);
      assert.deepStrictEqual([...seen].sort(), [...file.provenances].sort());
    }
  });

  it("goes a kind at a time, in time order, with unique IDs", () => {
    const ids = new Set<string>();
    let previous: { type: unknown; start: number } | undefined;
    for (const file of files) {
      for (const line of parse(file.text)) {
        if (line["entity"] === "health_provenance") continue;
        const key = `${String(line["entity"])}/${String(line["id"])}`;
        assert.isFalse(ids.has(key), key);
        ids.add(key);
        const row = line["row"] as Record<string, unknown>;
        const type = row["type"] ?? line["entity"];
        const start = (row["startDate"] ?? row["bucketStart"]) as number;
        if (previous !== undefined && previous.type === type) {
          assert.isAtLeast(start, previous.start);
        }
        previous = { type, start };
      }
    }
    assert.strictEqual(ids.size, 30_000);
  });

  it("is the same for the same seed, with sorted keys like the iPhone's", () => {
    assert.strictEqual([...syntheticBatches(options)][3]?.text, files[3]?.text);
    const line = files[0]?.text.split("\n")[1] ?? "";
    assert.strictEqual(sortedJson(JSON.parse(line)), line);
  });

  it("splits records into the mix's shares", () => {
    const counts = kindCounts(1_000_000);
    assert.strictEqual(
      counts.reduce((sum, count) => sum + count, 0),
      1_000_000,
    );
    assert.strictEqual(counts.length, kinds.length);
    assert.isAbove(counts[0] ?? 0, 300_000);
  });

  it("names provenance records by the hash of their sorted JSON", () => {
    const record = provenanceRecord({
      sourceName: "Synthetic Watch",
      sourceBundleId: "com.example",
      sourceRevision: { version: "26.0" },
      device: null,
    });
    const hash = createHash("sha256")
      .update('{"device":null,"sourceRevision":{"version":"26.0"}}')
      .digest("hex");
    assert.strictEqual(record.id, hash.slice(0, 32));
    assert.deepStrictEqual(record.row, { sourceRevision: { version: "26.0" }, device: null });
  });
});

const userId = "usr_000000000000000000000000bn" as UserId;
const deviceId = "dev_000000000000000000000000bn" as DeviceId;

const KnownUser = Layer.effectDiscard(
  Effect.gen(function* () {
    const sql = yield* SqlClient.SqlClient;
    yield* sql`INSERT INTO users (id, display_name, created_at) VALUES (${userId}, NULL, 0)`;
  }),
).pipe(Layer.orDie, Layer.provideMerge(TestCore));

layer(Layer.mergeAll(TestUserStores, TestHealthIngestion, KnownUser))("synthetic batches", (it) => {
  it.effect("apply on the server without a rejected line", () =>
    Effect.gen(function* () {
      const { files } = yield* TestHealthOutbox;
      const store = (yield* UserStores).forUser(userId);
      const batches = [...syntheticBatches({ ...options, records: 6000, fileRecords: 1000 })];
      let records = 0;
      const provenances = new Set<string>();
      for (const [index, file] of batches.entries()) {
        const batchId = `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`;
        files.set(healthBatchKey(userId, batchId), new Uint8Array(gzipSync(file.text)));
        yield* ingestHealthBatch({ userId, batchId, deviceId });
        const batch = yield* store.healthBatch(batchId);
        assert.strictEqual(batch?.status, "applied");
        assert.strictEqual(batch?.rejected ?? 0, 0, JSON.stringify(batch?.rejectedLines));
        records += file.records;
        for (const id of file.provenances) provenances.add(id);
      }
      // Every record, and each provenance the first time, appends one change: what the
      // benchmark waits for.
      const sql = (yield* TestStores).sqlFor(userId);
      const changes = sql?.exec("SELECT count(*) AS count FROM changes")[0]?.["count"];
      assert.strictEqual(changes, records + provenances.size);
      assert.strictEqual(records, 6000);
      // Every kind made it, including workouts and the iPhone's sums.
      const entities = sql
        ?.exec("SELECT DISTINCT entity FROM changes ORDER BY entity")
        .map((row) => row["entity"]);
      assert.deepStrictEqual(entities, [
        "health_provenance",
        "health_sample",
        "health_statistic",
        "health_workout",
      ]);
    }),
  );
});

describe("bench-sync helpers", () => {
  it("takes percentiles by nearest rank", () => {
    const values = [5, 1, 4, 2, 3, 6, 7, 8, 9, 10];
    assert.strictEqual(percentile(values, 50), 5);
    assert.strictEqual(percentile(values, 90), 9);
    assert.strictEqual(percentile(values, 100), 10);
    assert.strictEqual(percentile([0.4], 90), 0.4);
    assert.isNaN(percentile([], 50));
  });

  it("refuses prod", () => {
    assert.throws(() => checkNotProd("https://api.lil.tech", undefined), /prod/);
    assert.throws(() => checkNotProd("https://example.workers.dev", "prod"), /prod/);
    checkNotProd("https://api.staging.lil.tech", "staging");
    checkNotProd("https://lil-api-api-live-someone.851.workers.dev", "preview");
  });

  it("waits as long as a rate limit says, and backs off otherwise", () => {
    assert.strictEqual(retryDelay(429, 7, 1), 7000);
    assert.strictEqual(retryDelay(503, undefined, 1), 1000);
    assert.strictEqual(retryDelay(503, undefined, 3), 4000);
    assert.strictEqual(retryDelay(0, undefined, 10), 30_000);
  });

  it("reads options, with defaults and the environment", () => {
    const defaults = parseOptions([], {});
    assert.strictEqual(defaults.records, 200_000);
    assert.strictEqual(defaults.concurrency, 4);
    assert.isUndefined(defaults.url);
    assert.isFalse(defaults.keep);
    const big = parseOptions(["--records", "10_000_000", "--keep", "--seed", "3"], {
      LIL_BENCH_API_URL: "https://example.workers.dev",
    });
    assert.strictEqual(big.records, 10_000_000);
    assert.strictEqual(big.url, "https://example.workers.dev");
    assert.strictEqual(big.seed, 3);
    assert.isTrue(big.keep);
    // Someone's own account is kept.
    assert.isTrue(parseOptions([], { LIL_BENCH_REFRESH_TOKEN: "token" }).keep);
    assert.throws(() => parseOptions(["--records", "many"], {}), /--records/);
    assert.throws(() => parseOptions(["--bogus"], {}));
  });

  it("prints a table with items per second", () => {
    const table = formatTable([
      { stage: "Upload", items: 200_000, seconds: 20, note: "40 batches" },
      { stage: "Read", items: undefined, seconds: undefined, note: "not run" },
    ]);
    const lines = table.split("\n");
    assert.strictEqual(lines.length, 4);
    assert.include(lines[2], "200,000");
    assert.include(lines[2], "20.0");
    assert.include(lines[2], "10,000");
    assert.include(lines[3], "–");
    assert.match(lines[1] ?? "", /^\|-+\|-+:\|/);
  });
});
