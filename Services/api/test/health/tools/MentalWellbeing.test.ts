import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { healthMcpResultCeiling } from "../../../src/health/tools/HealthMcpServer.ts";
import { assessmentsLimit, stateOfMindLimit } from "../../../src/health/tools/HealthToolkit.ts";
import { healthAssessments, healthStateOfMind } from "../../../src/health/tools/MentalWellbeing.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what the
// Mental Wellbeing tools read on both servers (851-4160); this checks their caps, which a case
// would need hundreds of logs for: the count goes on past them, and a full answer fits.

const first = Date.parse("2026-01-01T08:00:00Z");
const hour = 60 * 60 * 1000;
const uuid = (index: number) => `0c0f0000-0000-4000-8000-${String(index).padStart(12, "0")}`;
const source = {
  sourceName: "Test Apple Watch",
  sourceBundleId: "com.apple.health.00000000-0000-4000-8000-000000000001",
};

/** `logs` State of Mind logs and `assessments` PHQ-9s, one every 11 hours from 1 January. */
const batch = (logs: number, assessments: number) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-10-20T12:00:00Z",
  lines: [
    ...Array.from({ length: logs }, (_, index) => ({
      entity: "health_state_of_mind",
      op: "upsert",
      id: uuid(index + 1),
      row: {
        startDate: first + index * 11 * hour,
        endDate: first + index * 11 * hour,
        kind: 1 + (index % 2),
        valence: -0.875,
        valenceClassification: 3,
        // Three feelings and two associations, the longest names, as a busy log has.
        labels: [12, 9, 37],
        associations: [2, 13],
        ...source,
      },
    })),
    ...Array.from({ length: assessments }, (_, index) => ({
      entity: "health_scored_assessment",
      op: "upsert",
      id: uuid(10_000 + index),
      row: {
        type: "HKScoredAssessmentTypeIdentifierPHQ9",
        startDate: first + index * 11 * hour,
        endDate: first + index * 11 * hour,
        score: 18,
        risk: 4,
        answers: [2, 2, 2, 2, 2, 2, 2, 2, 2],
        ...source,
      },
    })),
  ],
});

/** A long time zone name, with a half-hour offset, so every time is as long as it gets. */
const timeZone = "America/St_Johns";
const size = (result: unknown) => new TextEncoder().encode(JSON.stringify(result)).length;

describe("the Mental Wellbeing tools", () => {
  it.effect(`list at most ${stateOfMindLimit} logs, counting them all, under the ceiling`, () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(stateOfMindLimit + 100, 0)]);
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const result = yield* healthStateOfMind(sql, { range: "Y", timeZone });
      assert.strictEqual(result.count, stateOfMindLimit + 100);
      assert.strictEqual(result.logs.length, stateOfMindLimit);
      // The newest first.
      assert.strictEqual(result.logs[0]!.time, "2026-10-02T18:30:00-02:30");
      assert.deepStrictEqual(result.logs[0]!.labels, [
        "Embarrassed",
        "Disappointed",
        "Overwhelmed",
      ]);
      // 121 KB of 256.
      assert.isBelow(size(result), healthMcpResultCeiling);
    }),
  );

  it.effect(`list at most ${assessmentsLimit} assessments, counting them all`, () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(0, assessmentsLimit + 50)]);
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const result = yield* healthAssessments(sql, { range: "Y", timeZone });
      assert.strictEqual(result.count, assessmentsLimit + 50);
      assert.strictEqual(result.assessments.length, assessmentsLimit);
      assert.strictEqual(result.assessments[0]!.risk, "Moderately Severe");
      assert.isBelow(size(result), healthMcpResultCeiling / 4);
    }),
  );

  it.effect("count what they list when it all fits", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(3, 2)]);
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const logs = yield* healthStateOfMind(sql, { range: "Y" });
      assert.strictEqual(logs.count, 3);
      assert.strictEqual(logs.logs.length, 3);
      const assessments = yield* healthAssessments(sql, { range: "Y" });
      assert.strictEqual(assessments.count, 2);
      assert.strictEqual(assessments.assessments.length, 2);
    }),
  );
});
