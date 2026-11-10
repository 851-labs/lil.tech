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
  significant,
} from "../../src/health/MetadataValues.ts";

// How the Health tools read a metadata value at its edges (851-4170): blank text, Booleans
// written as numbers, enums' raw values out of range or not whole, quantities in both forms
// (`{ value, unit }` and descriptions, 851-4150) in units each quantity is or isn't read in,
// humidity's ×100, and dates in both forms. The Mac's
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

  it("reads a whole quantity, { value, unit }, in its unit", () => {
    const whole = (value: number, unit: string) => ({ value, unit });
    assert.strictEqual(quantity("length", whole(84.6012345, "m")), 84.6012345);
    assert.strictEqual(quantity("length", whole(123456789, "m")), 123456789);
    assert.strictEqual(quantity("heartRate", whole(120, "count/min")), 120);
    assert.strictEqual(quantity("mets", whole(9.876543, "kcal/hr·kg")), 9.876543);
    assert.strictEqual(quantity("vo2Max", whole(45.6789, "mL/min·kg")), 45.6789);
    assert.strictEqual(quantity("temperature", whole(15, "degC")), 15);
    // A percent is a fraction: 0.555 is 55.5%, and Apple's Workout app's 72 (7200%) is 72%.
    assert.strictEqual(quantity("humidity", whole(0.555, "%")), 55.5);
    assert.strictEqual(quantity("humidity", whole(72, "%")), 72);
    // Converted from any unit the quantity reads, as a description is.
    assert.strictEqual(quantity("length", whole(25, "yd")), 22.86);
    for (const measures of Object.keys(quantities) as Array<Quantity>) {
      if (measures === "humidity") continue;
      assert.strictEqual(quantity(measures, whole(7, quantities[measures].unit)), 7, measures);
    }
  });

  it("leaves out a whole quantity in another unit or not { value, unit }", () => {
    for (const other of [
      { value: 120, unit: "bpm" },
      { value: "120", unit: "count/min" },
      { value: true, unit: "count/min" },
      { value: null, unit: "count/min" },
      { value: 120 },
      { unit: "count/min" },
      { value: 120, unit: 1 },
      [120, "count/min"],
      {},
    ]) {
      assert.isNull(quantity("heartRate", other), JSON.stringify(other));
    }
  });

  it("reads a date as ISO 8601 or Unix milliseconds", () => {
    const date = metadataKinds.HKDateOfEarliestDataUsedForEstimate;
    assert.strictEqual(read(date, 1791763200000), 1791763200000);
    assert.strictEqual(read(date, { date: "2026-10-12T00:00:00.123Z" }), 1791763200123);
    assert.strictEqual(read(date, { date: "2026-10-12T00:00:00Z" }), 1791763200000);
    assert.strictEqual(read(date, { date: "2026-10-12T01:00:00.5+01:00" }), 1791763200500);
    assert.strictEqual(read(date, { date: "2026-10-11T19:30:00.12-04:30" }), 1791763200120);
    assert.strictEqual(read(date, { date: "2024-02-29T00:00:00Z" }), 1709164800000);
    assert.strictEqual(read(date, { date: "0001-01-01T00:00:00.000Z" }), -62135596800000);
    assert.strictEqual(read(date, { date: "9999-12-31T23:59:59.999Z" }), 253402300799999);
    for (const other of [
      // Fields out of their range, which a date parser might roll over.
      { date: "2026-10-12T00:00:60Z" },
      { date: "2026-02-29T00:00:00Z" },
      { date: "2026-04-31T00:00:00Z" },
      { date: "2026-13-01T00:00:00Z" },
      { date: "2026-00-10T00:00:00Z" },
      { date: "2026-10-00T00:00:00Z" },
      { date: "2026-10-12T24:00:00Z" },
      { date: "2026-10-12T00:60:00Z" },
      { date: "2026-10-12T00:00:00+24:00" },
      { date: "2026-10-12T00:00:00+01:60" },
      { date: "2026-10-12" },
      { date: "2026-10-12T00:00:00" },
      { date: "2026-10-12 00:00:00Z" },
      { date: "2026-10-12T00:00:00.1234Z" },
      { date: 1791763200000 },
      "2026-10-12T00:00:00Z",
      {},
      true,
      null,
    ]) {
      assert.isNull(read(date, other), JSON.stringify(other));
    }
  });

  it("rounds to 12 significant digits as the Mac does", () => {
    assert.strictEqual(significant(125.00000000000001), 125);
    assert.strictEqual(significant(0.30480000000000002), 0.3048);
    assert.strictEqual(significant(72.12345678901234), 72.123456789);
    assert.strictEqual(significant(123456789012345), 123456789012000);
    assert.strictEqual(significant(0), 0);
    assert.strictEqual(significant(-0.5), -0.5);
    // Halves round away from zero, as Swift's `rounded()` does, negative ones too.
    assert.strictEqual(significant(1234567890125), 1234567890130);
    assert.strictEqual(significant(-1234567890125), -1234567890130);
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
