import { assert, describe, it } from "@effect/vitest";
import { entities } from "../../src/store/Registry.ts";
import { type Batch, checkRecordKeys } from "./HealthConformance.ts";

// Synthetic data only (AGENTS.md).
const id = "0ca7d000-0000-4000-8000-000000000201";
const steps = "HKQuantityTypeIdentifierStepCount";
const batch = (...lines: ReadonlyArray<unknown>): Batch => ({
  device: "00000000-0000-4000-8000-0000000000d1",
  receivedAt: "2025-06-01T00:00:00Z",
  lines,
});
const sample = (type: string, startDate: number, value = 1) => ({
  entity: "health_sample",
  op: "upsert",
  id,
  row: { type, startDate, endDate: startDate + 60000, value },
});

describe("checkRecordKeys", () => {
  it("takes an ID sent again under the same key, and other entities' IDs", () => {
    checkRecordKeys([
      batch(sample(steps, 1748736000000), { entity: "health_sample", op: "delete", id }),
      batch(sample(steps, 1748736000000, 2), {
        entity: "health_workout",
        op: "upsert",
        id,
        row: { startDate: 1748740000000 },
      }),
    ]);
  });

  it("refuses an ID sent under another start or type, in any later batch (851-4181)", () => {
    assert.throws(
      () => checkRecordKeys([batch(sample(steps, 1748736000000)), batch(sample(steps, 1))]),
      `health_sample ${id} is sent under two keys`,
    );
    assert.throws(
      () =>
        checkRecordKeys([
          batch(
            sample(steps, 1748736000000),
            sample("HKQuantityTypeIdentifierHeartRate", 1748736000000),
          ),
        ]),
      "give it another ID",
    );
  });

  it("knows the keyed entities the Mac's check copies", () => {
    // Change `ConformanceBatch.keyFields` (`LilPackage/Tests/Health/HealthConformance`) with them.
    assert.deepStrictEqual(
      entities.filter((entity) => entity.key.length > 0).map((entity) => [entity.name, entity.key]),
      [["health_sample", ["type", "startDate"]]],
    );
  });
});
