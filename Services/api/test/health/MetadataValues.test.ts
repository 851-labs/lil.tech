import { assert, describe, it } from "@effect/vitest";
import { keptMetadataKeys } from "../../src/health/HealthCatalog.ts";
import {
  type MetadataKind,
  metadataKinds,
  metadataValue,
  type Quantity,
  quantities,
  quantity,
  readMetadataValue,
} from "../../src/health/MetadataValues.ts";

// How the Health tools read a metadata value at its edges (851-4170): blank text, Booleans
// written as numbers, enums' raw values out of range or not whole, quantity descriptions in
// units each quantity is or isn't read in, and humidity's ×100. The Mac's
// `HealthMetadataValuesTests` reads the same inputs alike. Synthetic data only.

const read = (kind: MetadataKind, value: unknown) => readMetadataValue(kind, value);

describe("MetadataValues", () => {
  it("reads only keys lil health keeps", () => {
    for (const key of Object.keys(metadataKinds)) assert.isTrue(keptMetadataKeys.has(key), key);
  });

  it("reads text unless it's blank", () => {
    const text = { kind: "text" } as const;
    assert.strictEqual(read(text, "Oatmeal"), "Oatmeal");
    assert.strictEqual(read(text, " a "), " a ");
    // Only spaces, tabs and line breaks are blank: a no-break space isn't.
    assert.strictEqual(read(text, " "), " ");
    for (const blank of ["", " ", " \t\n\r"]) assert.isNull(read(text, blank));
    for (const other of [1, true, null, undefined, {}]) assert.isNull(read(text, other));
  });

  it("reads numbers, not Booleans or strings", () => {
    const number = { kind: "number" } as const;
    assert.strictEqual(read(number, 2.5), 2.5);
    assert.strictEqual(read(number, -1), -1);
    for (const other of [true, false, "1", Infinity, Number.NaN, null]) {
      assert.isNull(read(number, other));
    }
  });

  it("reads Booleans, and 0 or 1 as one", () => {
    const boolean = { kind: "boolean" } as const;
    assert.strictEqual(read(boolean, true), true);
    assert.strictEqual(read(boolean, false), false);
    assert.strictEqual(read(boolean, 1), true);
    assert.strictEqual(read(boolean, 0), false);
    for (const other of [2, -1, 0.5, "1", "true", null]) assert.isNull(read(boolean, other));
  });

  it("reads an enum's case by a whole raw value with one", () => {
    const salinity = metadataKinds.HKMetadataKeyWaterSalinity;
    assert.strictEqual(read(salinity, 2), "saltWater");
    assert.strictEqual(read(salinity, 1), "freshWater");
    // 0 is the case that says nothing, 3 is past the last, and the rest aren't whole numbers.
    for (const other of [0, 3, -1, 1.5, "1", true, null]) assert.isNull(read(salinity, other));
  });

  it("reads a workout activity's name by its raw value", () => {
    const activity = { kind: "activity" } as const;
    assert.strictEqual(read(activity, 52), "Walking");
    // An activity the catalog doesn't name is a workout.
    assert.strictEqual(read(activity, 9999), "Workout");
    for (const other of [52.5, 1e16, "52", true]) assert.isNull(read(activity, other));
  });

  it("reads a quantity's description in its unit", () => {
    assert.strictEqual(quantity("heartRate", "120 count/min"), 120);
    assert.strictEqual(quantity("heartRate", "2 count/s"), 120);
    assert.strictEqual(quantity("length", "4250 cm"), 42.5);
    assert.strictEqual(quantity("length", ".5 km"), 500);
    assert.strictEqual(quantity("length", "5. m"), 5);
    assert.strictEqual(quantity("length", "-1.5e2 m"), -150);
    assert.strictEqual(quantity("duration", "1.5 hr"), 5400);
    assert.strictEqual(quantity("illuminance", "12.5 klx"), 12500);
    assert.strictEqual(quantity("vo2Max", "28.4 mL/min·kg"), 28.4);
    assert.strictEqual(quantity("mets", "6.25 kcal/hr·kg"), 6.25);
    assert.strictEqual(quantity("temperature", "212 degF"), 100);
    assert.strictEqual(quantity("temperature", "0 K"), -273.15);
    assert.closeTo(quantity("speed", "36 km/hr")!, 10, 1e-12);
  });

  it("reads each quantity in its own unit as it is", () => {
    for (const [measures, { unit }] of Object.entries(quantities)) {
      assert.strictEqual(quantity(measures as Quantity, `7 ${unit}`), 7, measures);
    }
  });

  it("reads humidity over 100 as 100 times too large", () => {
    const humidity = metadataKinds.HKWeatherHumidity;
    assert.strictEqual(read(humidity, "72 %"), 72);
    assert.strictEqual(read(humidity, "100 %"), 100);
    assert.strictEqual(read(humidity, "7200 %"), 72);
  });

  it("leaves out a quantity in another unit or not written as a description", () => {
    const heartRate = metadataKinds.HKHeartRateEventThreshold;
    for (const other of [
      "120 bpm",
      "3 dB",
      "120  count/min",
      "120count/min",
      " 120 count/min",
      "120 count/min ",
      "120",
      "count/min",
      "1e400 count/min",
      120,
      true,
      null,
    ]) {
      assert.isNull(read(heartRate, other), String(other));
    }
  });

  it("reads a key from metadata, or null when it's missing", () => {
    const metadata = { HKIndoorWorkout: 1, HKElevationAscended: "4250 cm" };
    assert.strictEqual(metadataValue(metadata, "HKIndoorWorkout"), true);
    assert.strictEqual(metadataValue(metadata, "HKElevationAscended"), 42.5);
    assert.isNull(metadataValue(metadata, "HKElevationDescended"));
    assert.isNull(metadataValue(null, "HKIndoorWorkout"));
    assert.isNull(metadataValue(undefined, "HKIndoorWorkout"));
  });
});
