import { assert, describe, it } from "@effect/vitest";
import { DateTime, Effect, Result, Schema } from "effect";
import timeZonesJson from "../../../time-zones.json" with { type: "json" };
import { namedTimeZone, toolTimeZone } from "../../../src/health/tools/ToolTime.ts";
import { readJson } from "../HealthConformance.ts";

// The names the tools' `timeZone` and records' `HKTimeZone` take (851-4184, 851-4185): the Swift
// core's `CardTimeZoneTests` runs the same cases against `CardTimeZone.named`.

const Cases = Schema.Struct({
  instants: Schema.Array(Schema.String),
  cases: Schema.Array(
    Schema.Struct({
      name: Schema.String,
      zone: Schema.Boolean,
      offsets: Schema.optionalKey(Schema.Array(Schema.Number)),
      properName: Schema.optionalKey(Schema.String),
    }),
  ),
});

const { instants, cases } = readJson(
  new URL("conformance/time-zones.json", import.meta.url),
  Cases,
);

describe("time zone names", () => {
  it.each(cases)("$name", ({ name, zone: isZone, offsets, properName }) => {
    const zone = namedTimeZone(name);
    assert.strictEqual(zone !== undefined, isZone);
    if (zone !== undefined && offsets !== undefined) {
      assert.deepStrictEqual(
        instants.map((instant) =>
          DateTime.zonedOffset(DateTime.makeZonedUnsafe(Date.parse(instant), { timeZone: zone })),
        ),
        offsets.map((seconds) => seconds * 1000),
      );
    }
    // The tools' error suggests the proper name, as the Mac's does.
    const result = Effect.runSync(Effect.result(toolTimeZone(name)));
    assert.deepStrictEqual(
      Result.isFailure(result) ? result.failure.message : undefined,
      isZone
        ? undefined
        : properName === undefined
          ? `Unknown time zone: ${name}. Use an IANA name, e.g. Europe/London.`
          : `Unknown time zone: ${name}. Did you mean ${properName}?`,
    );
  });

  // `Intl` knows every listed name, so this server takes each.
  it("Intl knows every name", () => {
    assert.deepStrictEqual(
      timeZonesJson.names.filter((name) => namedTimeZone(name) === undefined),
      [],
    );
  });

  // Every area's name `Intl` lists is listed. A newer ICU's new zone fails this until the list
  // has it (`CardTimeZone.names` says how to update it). Node is pinned (`.node-version`), so
  // this changes only when we update it. The Mac's tzdata isn't: Apple updates it on its own.
  it("every area's name Intl lists is listed", () => {
    const names = new Set(timeZonesJson.names);
    assert.deepStrictEqual(
      Intl.supportedValuesOf("timeZone").filter((name) => name.includes("/") && !names.has(name)),
      [],
    );
  });
});
