import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { healthSleep } from "../../../src/health/tools/Sleep.ts";
import { migrate } from "../../../src/store/Migrations.ts";
import { makeTestStoreSql } from "../../store/TestStoreSql.ts";

// The `sleep` tool's nights in the zone their records were recorded in (851-4175): the Mac's
// `sleepNamesANightByItsRecordedZone`. The tools' conformance cases check the rest on both
// servers. Synthetic data only (AGENTS.md).

const hour = 3_600_000;

describe("sleep", () => {
  // A night slept in Tokyo is Tokyo's night, the 20th, though the call's UTC reads 14:00 on the
  // 19th. Its times stay in the call's zone.
  it.effect("names a night by its recorded zone", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      migrate(sql);
      const stages = [
        [3, Date.UTC(2026, 9, 19, 14), 3.5],
        [5, Date.UTC(2026, 9, 19, 17, 30), 4],
      ] as const;
      stages.forEach(([stage, start, hours], index) =>
        sql.exec(
          `INSERT INTO health_sample (id, type, start_date, end_date, category_value, source_name,
            source_bundle_id, metadata)
          VALUES (?, 'HKCategoryTypeIdentifierSleepAnalysis', ?, ?, ?, 'Test', 'com.apple.health.watch', ?)`,
          `00000000-0000-4000-9000-${String(index).padStart(12, "0")}`,
          start,
          start + hours * hour,
          stage,
          '{"HKTimeZone":"Asia/Tokyo"}',
        ),
      );
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const result = yield* healthSleep(sql, { range: "W", timeZone: "UTC" });
      assert.deepStrictEqual(result.nights, [
        {
          date: "2026-10-20",
          start: "2026-10-19T14:00:00+00:00",
          end: "2026-10-19T21:30:00+00:00",
          inBed: 7.5 * 3600,
          asleep: 7.5 * 3600,
          awake: 0,
          core: 3.5 * 3600,
          deep: 0,
          rem: 4 * 3600,
          unspecified: 0,
        },
      ]);
    }),
  );
});
