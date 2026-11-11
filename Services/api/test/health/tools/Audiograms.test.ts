import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { healthAudiograms } from "../../../src/health/tools/Audiograms.ts";
import { healthMcpResultCeiling } from "../../../src/health/tools/HealthMcpServer.ts";
import { audiogramsLimit } from "../../../src/health/tools/HealthToolkit.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what
// `audiograms` reads on both servers; this checks its cap and size, which a case would need dozens
// of audiograms for.

const start = Date.parse("2026-09-01T06:00:00Z");
const audiogramId = (index: number) => `0c0f0000-0000-4000-8000-${String(index).padStart(12, "0")}`;

/** A clinic's audiogram at its longest: every frequency an audiometer tests, each ear masked and
 * unmasked, every result clamped on both sides, each value as long as one gets. */
const clinical = [125, 250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000].map(
  (frequency) => ({
    frequency,
    tests: [0, 1].flatMap((side) =>
      [false, true].map((masked) => ({
        side,
        type: 0,
        masked,
        sensitivity: -12.25,
        clampingLower: -12.25,
        clampingUpper: 112.75,
      })),
    ),
  }),
);

const audiogram = (index: number, points: unknown, startDate = start) => ({
  entity: "health_audiogram",
  op: "upsert",
  id: audiogramId(index),
  row: {
    startDate,
    endDate: startDate + 1_800_000,
    points,
    sourceName: "Test Audiometry App",
    sourceBundleId: "com.example.audiometry",
    metadata: { HKTimeZone: "America/St_Johns" },
  },
});

const batch = (lines: ReadonlyArray<unknown>) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-09-30T12:00:00Z",
  lines,
});

const size = (result: unknown) => new TextEncoder().encode(JSON.stringify(result)).length;

describe("audiograms", () => {
  it.effect(`list at most ${audiogramsLimit}, and count them all`, () =>
    Effect.gen(function* () {
      const lines = Array.from({ length: 40 }, (_, index) =>
        audiogram(index + 1, [], start + index * 3_600_000),
      );
      const sql = yield* storeWithBatches([batch(lines)]);
      yield* TestClock.setTime(Date.parse("2026-09-30T12:00:00Z"));
      const result = yield* healthAudiograms(sql, { range: "M" });
      assert.strictEqual(result.count, 40);
      assert.strictEqual(result.audiograms.length, audiogramsLimit);
      assert.strictEqual(result.audiograms[0]!.id, audiogramId(40));
    }),
  );

  it.effect(`give ${audiogramsLimit} of a clinic's longest audiograms in under the ceiling`, () =>
    Effect.gen(function* () {
      const lines = Array.from({ length: audiogramsLimit }, (_, index) =>
        audiogram(index + 1, clinical, start + index * 3_600_000),
      );
      const sql = yield* storeWithBatches([batch(lines)]);
      yield* TestClock.setTime(Date.parse("2026-09-30T12:00:00Z"));
      const result = yield* healthAudiograms(sql, { range: "M", timeZone: "America/St_Johns" });
      assert.strictEqual(result.audiograms.length, audiogramsLimit);
      const points = result.audiograms[0]!.points;
      assert.strictEqual(points.length, 11);
      assert.strictEqual(points[0]!.left.length, 2);
      assert.strictEqual(points[0]!.left[0]!.masked, false);
      assert.strictEqual(points[0]!.right[1]!.clampingUpper, 112.75);
      // 180 KB of 256, every test clamped; without clamping, about 120.
      assert.isBelow(size(result), healthMcpResultCeiling * 0.75);
    }),
  );
});
