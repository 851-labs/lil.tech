import { assert, describe, it } from "@effect/vitest";
import { Effect, Schema } from "effect";
import { cardCalendar, cardWeekdays } from "../../../src/health/cards/CardCalendar.ts";
import { cardRanges, CardSpec } from "../../../src/health/cards/CardSpec.ts";
import { canonicalCardSpec } from "../../../src/health/cards/CardSpecValidator.ts";
import { runCard } from "../../../src/health/cards/RunCard.ts";
import { startOfLocalDay } from "../../../src/health/tools/ToolTime.ts";
import type { StoreSql } from "../../../src/store/StoreSql.ts";
import type { Json } from "../../../src/health/cards/CardJson.ts";
import { matches, millis, readDataset, readJson, storeWithBatches } from "../HealthConformance.ts";

// The cards' conformance harness (851-3198, docs/decisions/cards.md › Conformance and tolerance).
// `conformance/dataset.json` extends the Health tools' synthetic account with nights, heart rate
// around sleep, workouts and more, and `conformance/cases.json` runs card specs on it, with the
// card data every engine must give, written by hand. This side ingests the dataset as the server
// ingests uploads and runs the server's engine directly (`runCard`). The Mac's
// (`CardConformanceTests`) runs the same cases after syncing the dataset with its sync engine,
// and the iPhone's (851-3201) after writing it into HealthKit, but for the cases marked
// `iphone.skip`.

const Case = Schema.Struct({
  name: Schema.String,
  note: Schema.optionalKey(Schema.String),
  spec: Schema.Unknown,
  range: Schema.Literals(cardRanges),
  date: Schema.String.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/)),
  timeZone: Schema.optionalKey(Schema.String),
  firstWeekday: Schema.optionalKey(Schema.Literals(cardWeekdays)),
  now: Schema.String,
  iphone: Schema.optionalKey(Schema.Struct({ skip: Schema.String })),
  expected: Schema.Unknown,
});

const batches = readDataset(new URL("conformance/dataset.json", import.meta.url));
const { cases } = readJson(
  new URL("conformance/cases.json", import.meta.url),
  Schema.Struct({ cases: Schema.Array(Case) }),
);

let store: StoreSql | undefined;

/** A case's spec, canonicalized as apps and tools write it. It must be valid. */
const canonicalSpec = (testCase: typeof Case.Type): CardSpec => {
  const result = canonicalCardSpec(testCase.spec as Json);
  assert.isUndefined(result.errors, `${testCase.name}: ${JSON.stringify(result.errors)}`);
  return Schema.decodeUnknownSync(CardSpec)(result.spec);
};

describe("card conformance cases", () => {
  it("are well formed: unique names, valid specs and times", () => {
    assert.isAbove(cases.length, 0);
    assert.strictEqual(new Set(cases.map((testCase) => testCase.name)).size, cases.length);
    for (const testCase of cases) {
      canonicalSpec(testCase);
      assert.isFalse(Number.isNaN(millis(testCase.now)), `${testCase.name}: now`);
    }
  });

  for (const testCase of cases) {
    it.effect(`the server: ${testCase.name}`, () =>
      Effect.gen(function* () {
        // The dataset, ingested once: the cases only read it.
        store ??= yield* storeWithBatches(batches);
        const sql = store;
        const calendar = yield* cardCalendar(testCase.timeZone, testCase.firstWeekday);
        const date = startOfLocalDay(testCase.date, calendar.zone);
        const output = runCard(
          sql,
          canonicalSpec(testCase),
          testCase.range,
          date,
          calendar,
          millis(testCase.now),
        );
        if (!matches(output, testCase.expected)) {
          // Shows the difference.
          assert.deepStrictEqual(output, testCase.expected);
        }
      }),
    );
  }
});
