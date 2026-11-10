import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import {
  healthMcpResultCeiling,
  makeHealthMcpServer,
} from "../../../src/health/tools/HealthMcpServer.ts";
import { routePointsLimit, routeShapeLimit } from "../../../src/health/tools/HealthToolkit.ts";
import {
  type HealthBlobReader,
  healthWorkoutRoute,
  healthWorkoutRoutePoints,
} from "../../../src/health/tools/WorkoutRoutes.ts";
import { agentClientHeader, agentGrantHeader } from "../../../src/mcp/AgentHeaders.ts";
import type { AgentAccess } from "../../../src/store/AgentAccessLog.ts";
import { postMcp, sessionless, viaStore } from "../../mcp/TestMcp.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what the
// route tools read on both servers; this checks their sizes on a long route, which a case would
// need tens of thousands of points for.

const start = Date.parse("2026-09-01T06:00:00Z");
const routeId = "0c0f0000-0000-4000-8000-0000000000f1";
const sha256 = "f1".repeat(32);

/** A day's route, a point a second, wandering, with every value known and long. */
const dayRoute = (count: number) => {
  const bytes = new Uint8Array(count * 44);
  const view = new DataView(bytes.buffer);
  for (let index = 0; index < count; index++) {
    const offset = index * 44;
    const angle = index / 900;
    view.setFloat64(offset, start / 1000 + index + 0.123456, true);
    view.setFloat64(offset + 8, -33.86785123456789 + Math.sin(angle) * 0.05 + index * 1e-7, true);
    view.setFloat64(offset + 16, 151.2073212345678 + Math.cos(angle) * 0.05, true);
    view.setFloat32(offset + 24, 1234.5678 + Math.sin(index) * 100, true);
    view.setFloat32(offset + 28, 12.345678, true);
    view.setFloat32(offset + 32, 23.456789, true);
    view.setFloat32(offset + 36, 3.456789, true);
    view.setFloat32(offset + 40, 359.12345, true);
  }
  return bytes;
};

const batch = (count: number) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-09-02T12:00:00Z",
  lines: [
    {
      entity: "health_workout_route",
      op: "upsert",
      id: routeId,
      row: {
        startDate: start,
        endDate: start + count * 1000,
        workout: null,
        locationCount: count,
        locations: sha256,
        sourceName: "Test Apple Watch",
        sourceBundleId: "com.apple.health.00000000-0000-4000-8000-000000000001",
      },
    },
  ],
});

const day = 24 * 60 * 60;
const blobs =
  (bytes: Uint8Array): HealthBlobReader =>
  (hash) =>
    Effect.succeed(hash === sha256 ? bytes : null);
/** A long time zone name, with a half-hour offset, so every time is as long as it gets. */
const timeZone = "America/St_Johns";

describe("workout routes", () => {
  it.effect("summarize a day's route in under the ceiling, its shape at most 500 points", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(day)]);
      const result = yield* healthWorkoutRoute(sql, blobs(dayRoute(day)), {
        id: routeId,
        timeZone,
      });
      assert.strictEqual(result.route.pointCount, day);
      assert.isAtMost(result.route.simplified.pointCount, routeShapeLimit);
      assert.isAbove(result.route.simplified.tolerance, 5);
      // 37 KB: 369 points at 80 m.
      const bytes = new TextEncoder().encode(JSON.stringify(result)).length;
      assert.isBelow(bytes, healthMcpResultCeiling / 4);
    }),
  );

  it.effect(`page ${routePointsLimit} points with every value known in under the ceiling`, () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(day)]);
      const result = yield* healthWorkoutRoutePoints(sql, blobs(dayRoute(day)), {
        id: routeId,
        timeZone,
        cursor: "5000",
        limit: routePointsLimit,
      });
      assert.strictEqual(result.points.length, routePointsLimit);
      assert.strictEqual(result.nextCursor, "6000");
      assert.strictEqual(result.points[0]!.time, "2026-09-01T04:53:20-02:30");
      assert.strictEqual(result.points[0]!.course, 359.12);
      // 198 KB of 256.
      const bytes = new TextEncoder().encode(JSON.stringify(result)).length;
      assert.isBelow(bytes, healthMcpResultCeiling);
    }),
  );

  it.effect("say when a route's points aren't on the server", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(10)]);
      const error = yield* Effect.flip(
        healthWorkoutRoute(sql, () => Effect.succeed(null), { id: routeId }),
      );
      assert.strictEqual(
        error.message,
        `The route ${routeId}'s points aren't on the server. Try again later.`,
      );
    }),
  );

  it.effect("log one row for a route, and a row a point for a page of points", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(10)]);
      const logged: Array<AgentAccess> = [];
      const server = yield* makeHealthMcpServer({
        sql,
        record: (access) => Effect.sync(() => void logged.push(access)),
        blobs: blobs(dayRoute(10)),
      });
      for (const [name, args] of [
        ["workout_route", { id: routeId }],
        ["workout_route_points", { id: routeId, limit: 4 }],
      ] as const) {
        const call = sessionless("tools/call", { name, arguments: args });
        const response = yield* postMcp(viaStore(server), "http://store/health", call.body, {
          ...call.headers,
          [agentGrantHeader]: "agr_01jbtest000000000000000000",
          [agentClientHeader]: "Test Agent",
        });
        const result = response.message?.["result"] as Record<string, unknown> | undefined;
        assert.notOk(result?.["isError"], JSON.stringify(result));
      }
      assert.deepInclude(logged[0], { tool: "workout_route", outcome: "ok", rows: 1 });
      assert.deepInclude(logged[1], { tool: "workout_route_points", outcome: "ok", rows: 4 });
    }),
  );
});
