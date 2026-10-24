import { assert, describe, it } from "@effect/vitest";
import { DateTime, Option } from "effect";
import type { CardCalendar } from "../../../src/health/cards/CardCalendar.ts";
import { runCard } from "../../../src/health/cards/RunCard.ts";
import { migrate } from "../../../src/store/Migrations.ts";
import { makeTestStoreSql } from "../../store/TestStoreSql.ts";
import { spec } from "./CardEngineSupport.ts";

// What a card costs the server's engine over a year (851-3197, `docs/BENCHMARK.md`, Cards on the
// server), on the Mac's `CardQueriesBenchmark` data: a year of heart rate a minute (525,600
// samples, several times what a Watch records) and as many of active energy, a year of a Watch's
// nights (10 records each) and a 45-minute workout a day, in a `node:sqlite` store. It prints the
// median of 5 runs' CPU time. Synthetic data only. Run it with
// `LIL_BENCHMARKS=1 vp test test/health/cards/CardEngineBenchmark.test.ts` in `Services/api`.

const heartRate = "HKQuantityTypeIdentifierHeartRate";
const energy = "HKQuantityTypeIdentifierActiveEnergyBurned";
const watch = "com.apple.health.81F3A2C4-5D6E-4F70-8A9B-0C1D2E3F4A5B";
const start = Date.UTC(2026, 0, 1);
const minutes = 525_600;

const london: CardCalendar = {
  zone: Option.getOrThrow(DateTime.zoneMakeNamed("Europe/London")),
  timeZone: "Europe/London",
  firstWeekday: "monday",
};

/** The process's CPU time, in milliseconds: unlike the wall clock, other processes don't count. */
const cpuMilliseconds = () => {
  const { user, system } = process.cpuUsage();
  return (user + system) / 1000;
};

/** The median of 5 runs of `body`, in CPU milliseconds. */
const median = (body: () => void) => {
  const times: Array<number> = [];
  for (let round = 0; round < 5; round++) {
    const before = cpuMilliseconds();
    body();
    times.push(cpuMilliseconds() - before);
  }
  return times.sort((a, b) => a - b)[2]!;
};

describe.skipIf(process.env["LIL_BENCHMARKS"] !== "1")("the card engine's benchmark", () => {
  it("runs a year of cards", { timeout: 600_000 }, () => {
    const sql = makeTestStoreSql();
    migrate(sql);
    sql.exec(
      "INSERT INTO health_provenance (id, source_revision, device) VALUES (?, NULL, ?)",
      "0".repeat(32),
      JSON.stringify({ name: "Apple Watch", model: "Watch" }),
    );
    // A minute's reading of each type, written by SQLite itself: a statement a row would take
    // longer than the benchmark.
    [heartRate, energy].forEach((type, index) =>
      sql.exec(
        `WITH RECURSIVE m(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM m WHERE i < ? - 1)
        INSERT INTO health_sample (id, type, start_date, end_date, value, unit, source_name,
          source_bundle_id, provenance)
        SELECT printf('%08x-0000-4000-8000-%012x', i, ?), ?, ? + i * 60000, ? + i * 60000 + 30000,
          50 + i % 60, 'count/min', 'Apple Watch', ?, ? FROM m`,
        minutes,
        index,
        type,
        start,
        start,
        watch,
        "0".repeat(32),
      ),
    );
    // A Watch's nights: in bed 22:30 to 07:15, two awake in the night; and a run or a ride at 6 PM.
    const stages = [
      [0, -1.5, 7.25],
      [3, -1, 0.5],
      [4, 0.5, 1.5],
      [3, 1.5, 2.5],
      [5, 2.5, 3.25],
      [2, 3.25, 3.33],
      [3, 3.33, 5],
      [5, 5, 6],
      [2, 6, 6.08],
      [3, 6.08, 7],
    ] as const;
    let id = 0;
    for (let day = 0; day < 366; day++) {
      const midnight = start + day * 86_400_000;
      for (const [stage, from, to] of stages) {
        sql.exec(
          `INSERT INTO health_sample (id, type, start_date, end_date, category_value, source_name,
            source_bundle_id) VALUES (?, 'HKCategoryTypeIdentifierSleepAnalysis', ?, ?, ?, 'Apple Watch', ?)`,
          `00000000-0000-4000-9000-${String(++id).padStart(12, "0")}`,
          midnight + from * 3_600_000,
          midnight + to * 3_600_000,
          stage,
          watch,
        );
      }
      sql.exec(
        `INSERT INTO health_workout (id, activity_type, start_date, end_date, duration, activities,
          events, statistics, source_name, source_bundle_id)
        VALUES (?, ?, ?, ?, 2700, '[]', '[]', '{}', 'Apple Watch', 'com.apple.health.watch')`,
        `00000000-0000-4000-a000-${String(day).padStart(12, "0")}`,
        day % 2 === 0 ? 37 : 13,
        midnight + 18 * 3_600_000,
        midnight + 18 * 3_600_000 + 2_700_000,
      );
    }

    const floor = median(() =>
      sql.rows(
        `SELECT start_date, end_date, value, source_bundle_id FROM health_sample
        WHERE type = ? AND start_date >= ? AND start_date < ?`,
        heartRate,
        start,
        start + 366 * 86_400_000,
      ),
    );
    console.log(`SQLite reading a year's rows: ${floor.toFixed(0)} ms`);

    const cards: ReadonlyArray<readonly [string, object, string, string]> = [
      ["heart rate, avg, by the day", { type: "Heart Rate" }, "day", "Y"],
      ["heart rate, avg, auto (by the month)", { type: "Heart Rate" }, "auto", "Y"],
      [
        "heart rate, max, of a device, by the day",
        { type: "Heart Rate", aggregation: "max", filter: { deviceModels: ["Watch"] } },
        "day",
        "Y",
      ],
      [
        "heart rate, first before noon, by the day",
        {
          type: "Heart Rate",
          aggregation: "first",
          window: { kind: "timeOfDay", from: "00:00", to: "12:00" },
        },
        "day",
        "Y",
      ],
      [
        "heart rate, asleep, by the night",
        { type: "Heart Rate", window: { kind: "asleep" } },
        "night",
        "Y",
      ],
      [
        "heart rate, 5 minutes before sleep, by the night",
        { type: "Heart Rate", window: { kind: "beforeSleep", minutes: 5 } },
        "night",
        "Y",
      ],
      [
        "heart rate, during runs, by the day",
        { type: "Heart Rate", window: { kind: "workout", activities: [37] } },
        "day",
        "Y",
      ],
      ["active energy from its samples, by the day", { type: "Active Energy" }, "day", "Y"],
    ];
    for (const [name, series, bucket, range] of cards) {
      const card = spec({
        version: 1,
        display: { name: "Card" },
        series: [series],
        formulas: [{ kind: "movingAverage", of: "a" }],
        bucket,
        range,
      });
      let points = 0;
      const time = median(() => {
        points = runCard(sql, card, "Y", start, london, start).series[0]!.points.length;
      });
      assert.isAbove(points, 10, name);
      console.log(`A year, ${name}: ${time.toFixed(0)} ms, ${points} points`);
    }
  });
});
