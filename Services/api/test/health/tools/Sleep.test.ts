import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import { healthSleep } from "../../../src/health/tools/Sleep.ts";
import { migrate } from "../../../src/store/Migrations.ts";
import { makeTestStoreSql } from "../../store/TestStoreSql.ts";

// The `sleep` tool's nights in the zone their records were recorded in (851-4175), and their
// recorded times (851-4177): the Mac's `sleepNamesANightByItsRecordedZone` and
// `sleepNamesANightsZoneAsItsRecordsDo`. The tools' conformance cases check the rest on both
// servers. Synthetic data only (AGENTS.md).

const hour = 3_600_000;

/** A store with a night's sleep records, each `[stage, start, hours]`, recorded in `zone`. */
const storeWithNight = (zone: string, stages: ReadonlyArray<readonly [number, number, number]>) => {
  const sql = makeTestStoreSql();
  migrate(sql);
  stages.forEach(([stage, start, hours], index) =>
    sql.exec(
      `INSERT INTO health_sample (id, type, start_date, end_date, category_value, source_name,
        source_bundle_id, metadata)
      VALUES (?, 'HKCategoryTypeIdentifierSleepAnalysis', ?, ?, ?, 'Test', 'com.apple.health.watch', ?)`,
      `00000000-0000-4000-9000-${String(index).padStart(12, "0")}`,
      start,
      start + hours * hour,
      stage,
      JSON.stringify({ HKTimeZone: zone }),
    ),
  );
  return sql;
};

describe("sleep", () => {
  // A night slept in Tokyo is Tokyo's night, the 20th, though the call's UTC reads 14:00 on the
  // 19th. Its times stay in the call's zone, and it adds its zone and its times on Tokyo's clock.
  it.effect("names a night by its recorded zone", () =>
    Effect.gen(function* () {
      const sql = storeWithNight("Asia/Tokyo", [
        [3, Date.UTC(2026, 9, 19, 14), 3.5],
        [5, Date.UTC(2026, 9, 19, 17, 30), 4],
      ]);
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const result = yield* healthSleep(sql, { range: "W", timeZone: "UTC" });
      assert.deepStrictEqual(result.nights, [
        {
          date: "2026-10-20",
          start: "2026-10-19T14:00:00+00:00",
          end: "2026-10-19T21:30:00+00:00",
          recordedTimeZone: "Asia/Tokyo",
          recordedStart: "2026-10-19T23:00:00+09:00",
          recordedEnd: "2026-10-20T06:30:00+09:00",
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

  // A night's zone is named as its records name it, as on the Mac, where `TimeZone` calls `UTC`
  // `GMT`; `Intl` would turn some aliases into other names.
  for (const [name, start, end] of [
    ["UTC", "2026-10-19T14:00:00+00:00", "2026-10-19T21:30:00+00:00"],
    ["Asia/Calcutta", "2026-10-19T19:30:00+05:30", "2026-10-20T03:00:00+05:30"],
  ] as const) {
    it.effect(`names a night's zone ${name} as its records do`, () =>
      Effect.gen(function* () {
        const sql = storeWithNight(name, [[3, Date.UTC(2026, 9, 19, 14), 7.5]]);
        yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
        const result = yield* healthSleep(sql, { range: "W", timeZone: "Europe/London" });
        assert.deepStrictEqual(
          result.nights.map(({ recordedTimeZone, recordedStart, recordedEnd }) => ({
            recordedTimeZone,
            recordedStart,
            recordedEnd,
          })),
          [{ recordedTimeZone: name, recordedStart: start, recordedEnd: end }],
        );
      }),
    );
  }
});
