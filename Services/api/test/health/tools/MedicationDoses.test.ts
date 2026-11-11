import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { healthMcpResultCeiling } from "../../../src/health/tools/HealthMcpServer.ts";
import { medicationDosesLimit } from "../../../src/health/tools/HealthToolkit.ts";
import { healthMedicationDoses } from "../../../src/health/tools/Medications.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what
// `medication_doses` reads on both servers (851-4167); this checks its cap and its pages, which a
// case would need hundreds of doses for: a full page fits under the ceiling, and paging through a
// year lists every dose once.

const first = Date.parse("2025-11-01T08:00:00Z");
const hour = 60 * 60 * 1000;
const uuid = (index: number) => `0c0f0000-0000-4000-8000-${String(index).padStart(12, "0")}`;
const medication = (letter: string) => letter.repeat(64);

/**
 * Two medications with long names, each due three times a day from 1 November 2025 for `days`
 * days, every dose taken late and recorded in a zone with a long name, as long as a dose gets.
 */
const batch = (days: number) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-10-20T12:00:00Z",
  lines: [
    ...["a", "b"].map((letter) => ({
      entity: "health_medication",
      op: "upsert",
      id: medication(letter),
      row: {
        name: `Synthetic Extended-Release Tablet ${letter.toUpperCase()} 500 mg`,
        nickname: null,
        generalForm: "tablet",
        isArchived: false,
        hasSchedule: true,
        codings: [],
      },
    })),
    ...Array.from({ length: days * 6 }, (_, index) => {
      const due = first + Math.floor(index / 2) * 8 * hour;
      return {
        entity: "health_medication_dose",
        op: "upsert",
        id: uuid(index + 1),
        row: {
          startDate: due + 1234567,
          endDate: due + 1234567,
          medication: medication(index % 2 === 0 ? "a" : "b"),
          logStatus: 4,
          scheduleType: 2,
          scheduledDate: due,
          scheduledDoseQuantity: 1.25,
          doseQuantity: 1.25,
          unit: "count",
          sourceName: "Test Health App With A Long Name",
          sourceBundleId: "com.example.health",
          metadata: { HKTimeZone: "America/Argentina/ComodRivadavia" },
        },
      };
    }),
  ],
});

/** A long time zone name, with a half-hour offset, so every time is as long as it gets. */
const timeZone = "America/St_Johns";
const size = (result: unknown) => new TextEncoder().encode(JSON.stringify(result)).length;

describe("medication_doses", () => {
  it.effect(`lists at most ${medicationDosesLimit} doses a page, under the ceiling`, () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(100)]);
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const result = yield* healthMedicationDoses(sql, {
        range: "Y",
        timeZone,
        limit: medicationDosesLimit,
      });
      assert.strictEqual(result.count, 600);
      assert.strictEqual(result.doses.length, medicationDosesLimit);
      assert.isNotNull(result.nextCursor);
      // The newest first: the last day's last dose, of the second medication.
      assert.strictEqual(result.doses[0]!.scheduledTime, "2026-02-08T20:30:00-03:30");
      assert.strictEqual(result.doses[0]!.recordedTimeZone, "America/Argentina/ComodRivadavia");
      // 127 KB of 256: a dose is about 500 bytes at its longest.
      assert.isBelow(size(result), healthMcpResultCeiling / 2);
    }),
  );

  it.effect("pages through a year, every dose once, the count the same on each page", () =>
    Effect.gen(function* () {
      // Up to 7 October 2026, in the year ending 20 October.
      const sql = yield* storeWithBatches([batch(340)]);
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const seen: Array<string> = [];
      let cursor: string | undefined;
      let pages = 0;
      do {
        const page = yield* healthMedicationDoses(sql, {
          range: "Y",
          limit: medicationDosesLimit,
          ...(cursor === undefined ? {} : { cursor }),
        });
        assert.strictEqual(page.count, 2040);
        seen.push(...page.doses.map((dose) => `${dose.scheduledTime} ${dose.medicationId}`));
        cursor = page.nextCursor ?? undefined;
        pages += 1;
      } while (cursor !== undefined);
      assert.strictEqual(pages, 9);
      assert.strictEqual(new Set(seen).size, 2040);
      assert.deepStrictEqual(seen, [...seen].sort().reverse());
    }),
  );

  it.effect("counts what it lists when it all fits on the first page", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch(2)]);
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const result = yield* healthMedicationDoses(sql, { range: "Y" });
      assert.strictEqual(result.count, 12);
      assert.strictEqual(result.doses.length, 12);
      assert.isNull(result.nextCursor);
    }),
  );
});
