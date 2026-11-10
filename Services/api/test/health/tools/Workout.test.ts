import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import {
  healthMcpResultCeiling,
  makeHealthMcpServer,
} from "../../../src/health/tools/HealthMcpServer.ts";
import { workoutEventsLimit } from "../../../src/health/tools/HealthToolkit.ts";
import { healthWorkout } from "../../../src/health/tools/Workout.ts";
import { agentClientHeader, agentGrantHeader } from "../../../src/mcp/AgentHeaders.ts";
import type { AgentAccess } from "../../../src/store/AgentAccessLog.ts";
import { postMcp, sessionless, viaStore } from "../../mcp/TestMcp.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what
// `workout` reads on both servers; this checks its caps, which a case would need hundreds of
// events for.

const start = Date.parse("2026-09-01T06:00:00Z");
const second = 1000;

/** Everything a lap or segment can say, so each takes the most room it can. */
const intervalMetadata = {
  HKSwimmingStrokeStyle: 4,
  HKSWOLFScore: 48.5,
  HKLapLength: "25 yd",
  HKAverageSpeed: "0.762 m/s",
  HKMaximumSpeed: "0.914 m/s",
};

/** Events of `type`, one a second, each 1 second long. */
const events = (type: number, count: number) =>
  Array.from({ length: count }, (_, index) => ({
    type,
    startDate: start + index * second,
    endDate: start + (index + 1) * second,
    metadata: intervalMetadata,
  }));

const swim = (laps: number, segments: number, pauses: number) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-09-02T00:00:00Z",
  lines: [
    {
      entity: "health_workout",
      op: "upsert",
      id: "0c0f0000-0000-4000-8000-0000000000e1",
      row: {
        activityType: 46,
        startDate: start,
        endDate: start + 7200 * second,
        duration: 7200,
        activities: [],
        events: [
          ...events(3, laps),
          ...events(7, segments),
          ...Array.from({ length: pauses }, (_, index) => [
            { type: 1, startDate: start + index * 2 * second, endDate: start + index * 2 * second },
            {
              type: 2,
              startDate: start + (index * 2 + 1) * second,
              endDate: start + (index * 2 + 1) * second,
            },
          ]).flat(),
        ],
        statistics: {},
        sourceName: "Test Apple Watch",
        sourceBundleId: "com.apple.health.00000000-0000-4000-8000-000000000001",
      },
    },
  ],
});

describe("workout", () => {
  it.effect(
    `lists at most ${workoutEventsLimit} laps, segments and pauses, and counts them all`,
    () =>
      Effect.gen(function* () {
        const over = workoutEventsLimit + 1;
        const sql = yield* storeWithBatches([swim(over, over, over)]);
        const result = yield* healthWorkout(sql, { id: "0c0f0000-0000-4000-8000-0000000000e1" });
        const { workout } = result;
        assert.strictEqual(workout.lapCount, over);
        assert.strictEqual(workout.laps.length, workoutEventsLimit);
        assert.strictEqual(workout.segmentCount, over);
        assert.strictEqual(workout.segments.length, workoutEventsLimit);
        assert.strictEqual(workout.pauseCount, over);
        assert.strictEqual(workout.pauses.length, workoutEventsLimit);
        // The first ones.
        assert.strictEqual(workout.laps[0]!.start, "2026-09-01T06:00:00+00:00");
        assert.strictEqual(workout.pauses.at(-1)!.start, "2026-09-01T06:09:58+00:00");
        // Even then, with a stroke, SWOLF, pool length and speeds on every lap and segment, the
        // answer fits under the MCP servers' ceiling (138 KB of 256).
        const bytes = new TextEncoder().encode(JSON.stringify(result)).length;
        assert.isBelow(bytes, healthMcpResultCeiling);
      }),
  );

  it.effect("logs one row: the workout, whatever its laps, segments and pauses", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([swim(3, 2, 1)]);
      const logged: Array<AgentAccess> = [];
      const server = yield* makeHealthMcpServer({
        sql,
        record: (access) => Effect.sync(() => void logged.push(access)),
      });
      const call = sessionless("tools/call", {
        name: "workout",
        arguments: { id: "0c0f0000-0000-4000-8000-0000000000e1" },
      });
      const response = yield* postMcp(viaStore(server), "http://store/health", call.body, {
        ...call.headers,
        [agentGrantHeader]: "agr_01jbtest000000000000000000",
        [agentClientHeader]: "Test Agent",
      });
      assert.notOk((response.message?.["result"] as Record<string, unknown>)["isError"]);
      assert.deepInclude(logged[0], { tool: "workout", outcome: "ok", rows: 1 });
    }),
  );
});
