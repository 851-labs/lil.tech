import { assert, describe, it } from "@effect/vitest";
import { Schema } from "effect";
import {
  cardPositionBetween,
  cardPositionError,
  cardPositionsBetween,
} from "../../../src/health/cards/CardPosition.ts";
import { CardSpec } from "../../../src/health/cards/CardSpec.ts";
import {
  canonicalCardSpec,
  type CardSpecError,
  storedCardSpecErrors,
} from "../../../src/health/cards/CardSpecValidator.ts";
import type { JsonObject } from "../../../src/health/cards/CardJson.ts";
import schemaFile from "../../../card-spec.schema.json" with { type: "json" };
import cases from "./validation-cases.json" with { type: "json" };

// The server's port of the Swift card spec validator and positions (851-3202) against the cases
// the Swift generates (`scripts/generate-health-cards`): the same canonical forms, and the same
// errors, word for word and in order.

type Json = Schema.Json;

interface SpecCase {
  readonly name: string;
  readonly mode: "input" | "stored";
  readonly spec: Json;
  readonly canonical?: Json;
  readonly errors?: ReadonlyArray<CardSpecError>;
}

const specCases = cases.specs as unknown as ReadonlyArray<SpecCase>;

const throwsOrNull = <A>(make: () => A): A | null => {
  try {
    return make();
  } catch {
    return null;
  }
};

describe("card spec validation", () => {
  it("has cases for every mode", () => {
    assert.isAbove(specCases.filter((item) => item.mode === "input").length, 100);
    assert.isAbove(specCases.filter((item) => item.mode === "stored").length, 5);
  });

  for (const item of specCases) {
    it(`${item.mode}: ${item.name}`, () => {
      if (item.mode === "stored") {
        assert.deepStrictEqual(storedCardSpecErrors(item.spec), item.errors);
        return;
      }
      const result = canonicalCardSpec(item.spec);
      if (item.canonical !== undefined) {
        assert.deepStrictEqual(result, { spec: item.canonical as JsonObject });
        // A canonical spec is what the store keeps, and its structure is `CardSpec`'s.
        assert.deepStrictEqual(storedCardSpecErrors(item.canonical), []);
        Schema.decodeUnknownSync(CardSpec)(item.canonical, { onExcessProperty: "error" });
      } else {
        assert.deepStrictEqual(result, { errors: item.errors ?? [] });
      }
    });
  }

  it("compares a stored spec with its canonical form by value, not text", () => {
    const canonical = specCases.find((item) => item.canonical !== undefined)?.canonical;
    // Parsed from a writer that spells numbers otherwise (Swift's `1e-07`), and reordered.
    const spec = JSON.parse(
      JSON.stringify({
        ...(canonical as object),
        chart: { goal: { value: 1e-7 }, style: "ranges" },
      }).replace("1e-7", "1e-07"),
    ) as Json;
    assert.deepStrictEqual(storedCardSpecErrors(spec), []);
  });
});

describe("the card spec's schema", () => {
  it("is the JSON Schema the Swift generates", () => {
    const document = Schema.toJsonSchemaDocument(CardSpec, { onExcessProperty: "error" });
    const { $schema, title: _title, description: _description, ...expected } = schemaFile;
    assert.strictEqual($schema, "https://json-schema.org/draft/2020-12/schema");
    assert.deepStrictEqual(document.definitions, {});
    assert.deepStrictEqual(document.schema, expected);
  });
});

describe("card positions", () => {
  it("are between two others as the Swift places them", () => {
    for (const { a, b, position } of cases.positions.between) {
      assert.strictEqual(
        throwsOrNull(() => cardPositionBetween(a, b)),
        position,
        `${a} ${b}`,
      );
    }
  });

  it("come several at a time, ascending", () => {
    for (const { a, b, count, positions } of cases.positions.betweenCount) {
      assert.deepStrictEqual(
        throwsOrNull(() => cardPositionsBetween(a, b, count)),
        positions,
        `${a} ${b} ${count}`,
      );
    }
  });

  it("are checked as the store checks them", () => {
    for (const { position, error } of cases.positions.validity) {
      assert.deepStrictEqual(cardPositionError(position) ?? null, error, position);
    }
  });
});
