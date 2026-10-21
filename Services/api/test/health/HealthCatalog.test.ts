import { assert, describe, it } from "@effect/vitest";
import {
  healthCatalogType,
  healthCatalogTypes,
  healthCategories,
  healthCategoryName,
  workoutActivityName,
} from "../../src/health/HealthCatalog.ts";

// The catalog is generated from the Swift one (scripts/generate-health-catalog), which
// `scripts/format --lint` and HealthCatalogTests check is fresh. These check the server reads it:
// that it decodes (so a case Swift adds fails here until the schemas have it) and what the tools
// look up, against values the Mac shows.
describe("HealthCatalog", () => {
  it("decodes every type, once", () => {
    const ids = healthCatalogTypes.map((type) => type.id);
    assert.isAbove(ids.length, 200);
    assert.strictEqual(new Set(ids).size, ids.length);
  });

  it("names a type, its category, unit and aggregation style", () => {
    const steps = healthCatalogType("HKQuantityTypeIdentifierStepCount");
    assert.deepStrictEqual(
      steps && [steps.name, steps.kind, steps.category, steps.unit, steps.aggregation],
      ["Steps", "quantity", "activity", "count", "cumulative"],
    );
    const heartRate = healthCatalogType("HKQuantityTypeIdentifierHeartRate");
    assert.deepStrictEqual(
      heartRate && [heartRate.name, heartRate.category, heartRate.alsoListedIn, heartRate.unit],
      ["Heart Rate", "heart", ["vitals"], "count/min"],
    );
    assert.strictEqual(heartRate?.aggregation, "discreteTemporallyWeighted");
    assert.strictEqual(
      healthCatalogType("HKQuantityTypeIdentifierBodyMass")?.aggregation,
      "discreteArithmetic",
    );
    assert.strictEqual(
      healthCatalogType("HKQuantityTypeIdentifierEnvironmentalAudioExposure")?.aggregation,
      "discreteEquivalentContinuousLevel",
    );
    assert.isUndefined(healthCatalogType("HKQuantityTypeIdentifierNotAType"));
  });

  it("gives only quantities units and aggregation styles, and only characteristics no category", () => {
    for (const type of healthCatalogTypes) {
      const quantity = type.kind === "quantity";
      assert.strictEqual(type.unit !== null, quantity, type.id);
      assert.strictEqual(type.aggregation !== null, quantity, type.id);
      assert.strictEqual(type.category === null, type.kind === "characteristic", type.id);
    }
  });

  it("names categories in Browse's order", () => {
    assert.strictEqual(healthCategories[0], "activity");
    assert.strictEqual(healthCategories.at(-1), "otherData");
    assert.strictEqual(healthCategoryName("bodyMeasurements"), "Body Measurements");
    assert.strictEqual(healthCategoryName("otherData"), "Other Data");
  });

  it("names workout activities as the Mac does, else Workout", () => {
    assert.strictEqual(workoutActivityName(37), "Running");
    assert.strictEqual(workoutActivityName(63), "High Intensity Interval Training");
    assert.strictEqual(workoutActivityName(3000), "Other");
    assert.strictEqual(workoutActivityName(9999), "Workout");
  });
});
