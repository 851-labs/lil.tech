import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { healthMcpResultCeiling } from "../../../src/health/tools/HealthMcpServer.ts";
import {
  heartbeatBeatsDefaultLimit,
  heartbeatBeatsLimit,
  heartbeatSeriesLimit,
} from "../../../src/health/tools/HealthToolkit.ts";
import {
  healthHeartbeatSeries,
  healthHeartbeatSeriesBeats,
} from "../../../src/health/tools/HeartbeatSeries.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what the
// heartbeat series tools read on both servers; this checks their caps and sizes, which a case
// would need thousands of beats for.

const start = Date.parse("2026-09-01T06:00:00Z");
const seriesId = (index: number) => `be470000-0000-4000-8000-${String(index).padStart(12, "0")}`;

/** `count` beats a second and a quarter apart, from 80,000 s: each time and interval as long as they get. */
const longBeats = (count: number) =>
  Array.from(
    { length: count },
    (_, index) => Math.round((80_000 + index * 1.2345) * 10_000) / 10_000,
  );

const series = (index: number, beats: ReadonlyArray<number>, startDate = start) => ({
  entity: "health_heartbeat_series",
  op: "upsert",
  id: seriesId(index),
  row: {
    startDate,
    endDate: startDate + 60_000,
    beats,
    gaps: [],
    sourceName: "Test Apple Watch",
    sourceBundleId: "com.apple.health.00000000-0000-4000-8000-000000000001",
    metadata: { HKTimeZone: "America/St_Johns" },
  },
});

const batch = (lines: ReadonlyArray<unknown>) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-09-30T12:00:00Z",
  lines,
});

const size = (result: unknown) => new TextEncoder().encode(JSON.stringify(result)).length;

describe("heartbeat series", () => {
  it.effect(`give at most ${heartbeatBeatsLimit} beats a page, in under the ceiling`, () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch([series(1, longBeats(2500))])]);
      const page = yield* healthHeartbeatSeriesBeats(sql, {
        id: seriesId(1),
        timeZone: "America/St_Johns",
        limit: heartbeatBeatsLimit,
      });
      assert.strictEqual(page.beats.length, heartbeatBeatsLimit);
      assert.deepStrictEqual(page.beats[1], {
        time: 80_001.2345,
        interval: 1234.5,
        precededByGap: false,
      });
      assert.strictEqual(page.nextCursor, String(heartbeatBeatsLimit));
      // About 120 KB of 256.
      assert.isBelow(size(page), healthMcpResultCeiling * 0.5);
      // A page is 1,000 beats by default.
      const first = yield* healthHeartbeatSeriesBeats(sql, { id: seriesId(1) });
      assert.strictEqual(first.beats.length, heartbeatBeatsDefaultLimit);
      assert.strictEqual(first.nextCursor, String(heartbeatBeatsDefaultLimit));
    }),
  );

  it.effect(`list at most ${heartbeatSeriesLimit} series, and count them all`, () =>
    Effect.gen(function* () {
      const lines = Array.from({ length: 150 }, (_, index) =>
        series(index + 1, longBeats(100), start + index * 3_600_000),
      );
      const sql = yield* storeWithBatches([batch(lines)]);
      yield* TestClock.setTime(Date.parse("2026-09-30T12:00:00Z"));
      const result = yield* healthHeartbeatSeries(sql, { range: "M" });
      assert.strictEqual(result.count, 150);
      assert.strictEqual(result.series.length, heartbeatSeriesLimit);
      assert.strictEqual(result.series[0]!.id, seriesId(150));
      assert.strictEqual(result.series[0]!.intervalCount, 99);
      assert.isBelow(size(result), healthMcpResultCeiling / 4);
    }),
  );
});
