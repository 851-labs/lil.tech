import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import {
  healthElectrocardiograms,
  healthElectrocardiogramVoltages,
} from "../../../src/health/tools/Electrocardiograms.ts";
import { healthMcpResultCeiling } from "../../../src/health/tools/HealthMcpServer.ts";
import {
  electrocardiogramsLimit,
  voltagesValueLimit,
} from "../../../src/health/tools/HealthToolkit.ts";
import type { HealthBlobReader } from "../../../src/health/tools/WorkoutRoutes.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what the
// ECG tools read on both servers; this checks their caps and sizes, which a case would need tens
// of thousands of measurements for.

const start = Date.parse("2026-09-01T06:00:00Z");
const ecgId = (index: number) => `0c0f0000-0000-4000-8000-${String(index).padStart(12, "0")}`;
const sha256 = "e1".repeat(32);

/** `count` measurements in microvolts, each as long as a value gets (-12345.67). */
const longVoltages = (count: number) => {
  const bytes = new Uint8Array(count * 4);
  const view = new DataView(bytes.buffer);
  for (let index = 0; index < count; index++) view.setFloat32(index * 4, -12345.67, true);
  return bytes;
};

const recording = (index: number, count: number, samplingFrequency: number, startDate = start) => ({
  entity: "health_electrocardiogram",
  op: "upsert",
  id: ecgId(index),
  row: {
    startDate,
    endDate: startDate + 30_000,
    classification: 1,
    symptomsStatus: 1,
    averageHeartRate: 70,
    samplingFrequency,
    voltageCount: count,
    voltages: count > 0 ? sha256 : null,
    sourceName: "ECG",
    sourceBundleId: "com.apple.NanoHeartRhythm",
  },
});

const batch = (lines: ReadonlyArray<unknown>) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-09-30T12:00:00Z",
  lines,
});

const blobs =
  (bytes: Uint8Array): HealthBlobReader =>
  (hash) =>
    Effect.succeed(hash === sha256 ? bytes : null);

const size = (result: unknown) => new TextEncoder().encode(JSON.stringify(result)).length;

describe("ECGs", () => {
  it.effect("give a whole Apple Watch recording, 30 seconds at 512 Hz, in under the ceiling", () =>
    Effect.gen(function* () {
      const count = 30 * 512;
      const sql = yield* storeWithBatches([batch([recording(1, count, 512)])]);
      const result = yield* healthElectrocardiogramVoltages(sql, blobs(longVoltages(count)), {
        id: ecgId(1),
        timeZone: "America/St_Johns",
        seconds: 30,
      });
      assert.strictEqual(result.values.length, count);
      assert.strictEqual(result.measurementsPerValue, 1);
      assert.strictEqual(result.rate, 512);
      assert.strictEqual(result.values[0], -12345.67);
      assert.isNull(result.nextCursor);
      // 154 KB of 256.
      assert.isBelow(size(result), healthMcpResultCeiling * 0.65);
    }),
  );

  it.effect("downsample a page that would have more values than the limit", () =>
    Effect.gen(function* () {
      const count = 30 * 1000;
      const sql = yield* storeWithBatches([batch([recording(1, count, 1000)])]);
      const result = yield* healthElectrocardiogramVoltages(sql, blobs(longVoltages(count)), {
        id: ecgId(1),
        seconds: 30,
      });
      assert.strictEqual(result.measurementsPerValue, 2);
      assert.strictEqual(result.rate, 500);
      assert.strictEqual(result.values.length, count / 2);
      assert.isAtMost(result.values.length, voltagesValueLimit);
      assert.strictEqual(result.values[0], -12345.67);
      assert.isBelow(size(result), healthMcpResultCeiling);
      // 10 seconds, the default, aren't.
      const page = yield* healthElectrocardiogramVoltages(sql, blobs(longVoltages(count)), {
        id: ecgId(1),
      });
      assert.strictEqual(page.measurementsPerValue, 1);
      assert.strictEqual(page.values.length, 10_000);
      assert.strictEqual(page.nextCursor, "10000");
    }),
  );

  it.effect("say when a recording's voltages aren't on the server", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch([recording(1, 10, 512)])]);
      const error = yield* Effect.flip(
        healthElectrocardiogramVoltages(sql, () => Effect.succeed(null), { id: ecgId(1) }),
      );
      assert.strictEqual(
        error.message,
        "The ECG's voltages aren't on the server. Try again later.",
      );
    }),
  );

  it.effect(`list at most ${electrocardiogramsLimit} recordings, and count them all`, () =>
    Effect.gen(function* () {
      const lines = Array.from({ length: 150 }, (_, index) =>
        recording(index + 1, 0, 512, start + index * 3_600_000),
      );
      const sql = yield* storeWithBatches([batch(lines)]);
      yield* TestClock.setTime(Date.parse("2026-09-30T12:00:00Z"));
      const result = yield* healthElectrocardiograms(sql, { range: "M" });
      assert.strictEqual(result.count, 150);
      assert.strictEqual(result.recordings.length, electrocardiogramsLimit);
      assert.strictEqual(result.recordings[0]!.id, ecgId(150));
      assert.isBelow(size(result), healthMcpResultCeiling / 4);
    }),
  );
});
