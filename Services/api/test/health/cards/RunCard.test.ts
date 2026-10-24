import { assert, describe, it } from "@effect/vitest";
import { Effect, Schema } from "effect";
import { TestClock } from "effect/testing";
import { CardSpec } from "../../../src/health/cards/CardSpec.ts";
import { cardData, cardHeadline, runCard } from "../../../src/health/cards/RunCard.ts";
import { welcomeSeed } from "../../../src/health/cards/WelcomeSeed.ts";
import { HealthToolError } from "../../../src/health/tools/HealthToolkit.ts";
import { migrate } from "../../../src/store/Migrations.ts";
import type { StoreSql } from "../../../src/store/StoreSql.ts";
import { makeTestStoreSql } from "../../store/TestStoreSql.ts";
import {
  addDays,
  date,
  heartRate,
  hour,
  london,
  minute,
  spec,
  steps,
} from "./CardEngineSupport.ts";

// The server's card engine on a user's store (851-3197): what it reads (statistics and samples,
// filters through the sample's device or its provenance's, tombstones, sleep records and
// workouts), and the entry points' output as the tools give it. The engine's rules are
// CardEngine.test.ts' and CardWindows.test.ts'. Synthetic data only (AGENTS.md).

const seed = (index: number) => Schema.decodeUnknownSync(CardSpec)(welcomeSeed[index]!.spec);
const watch = "com.apple.health.watch";
const phone = "com.apple.health.phone";
const iPhone = "dev_00000000000000000000000ph1";
const sleepType = "HKCategoryTypeIdentifierSleepAnalysis";

let ids = 0;
const nextId = () => `00000000-0000-4000-8000-${String(++ids).padStart(12, "0")}`;

const makeStore = (): StoreSql => {
  const sql = makeTestStoreSql();
  migrate(sql);
  return sql;
};

const insertSample = (
  sql: StoreSql,
  sample: {
    readonly type: string;
    readonly start: number;
    readonly end?: number;
    readonly value?: number | null;
    readonly categoryValue?: number | null;
    readonly source?: string;
    readonly device?: string | null;
    readonly provenance?: string | null;
    readonly id?: string;
  },
) => {
  const id = sample.id ?? nextId();
  sql.exec(
    `INSERT INTO health_sample (id, type, start_date, end_date, value, unit, category_value,
      source_name, source_bundle_id, device, provenance)
    VALUES (?, ?, ?, ?, ?, NULL, ?, 'Synthetic', ?, ?, ?)`,
    id,
    sample.type,
    sample.start,
    sample.end ?? sample.start + minute,
    sample.value === undefined ? null : sample.value,
    sample.categoryValue ?? null,
    sample.source ?? watch,
    sample.device ?? null,
    sample.provenance ?? null,
  );
  return id;
};

/** The iPhone whose statistics count, and a 30-minute sum of a type. */
const insertStatistic = (sql: StoreSql, type: string, bucketStart: number, sum: number) => {
  sql.exec(
    `INSERT OR IGNORE INTO health_statistics_device (id, device, paired_with_watch, reported_at)
    VALUES (?, ?, 1, ?)`,
    iPhone,
    iPhone,
    date(10, 20),
  );
  sql.exec(
    `INSERT INTO health_statistic (id, device, type, bucket_start, sum, unit)
    VALUES (?, ?, ?, ?, ?, 'count')`,
    `${iPhone}/${type}@${bucketStart}`,
    iPhone,
    type,
    bucketStart,
    sum,
  );
};

const now = date(10, 20, 15);

describe("runCard", () => {
  it("totals a cumulative type from the statistics, then the samples past them", () => {
    const sql = makeStore();
    // 3,000 steps a day from Monday to Wednesday in statistics, and Wednesday afternoon's samples,
    // synced before their sums.
    for (const day of [19, 20, 21]) {
      for (const at of [9, 12, 17]) insertStatistic(sql, steps, date(10, day, at), 1000);
    }
    insertSample(sql, { type: steps, start: date(10, 21, 18), value: 400, source: phone });
    insertSample(sql, { type: steps, start: date(10, 21, 18, 30), value: 100, source: phone });
    // Samples the statistics cover don't count twice.
    insertSample(sql, { type: steps, start: date(10, 20, 9), value: 1000, source: phone });
    const data = runCard(sql, seed(0), "W", date(10, 20), london, now);
    assert.deepStrictEqual(data, {
      range: "W",
      start: "2026-10-19",
      end: "2026-10-25",
      timeZone: "Europe/London",
      firstWeekday: "monday",
      bucket: "auto",
      grain: "day",
      series: [
        {
          id: "a",
          label: "Steps",
          type: steps,
          aggregation: "sum",
          unit: "count",
          hidden: false,
          points: [
            {
              start: "2026-10-19T00:00:00+01:00",
              value: 3000,
              minimum: 3000,
              maximum: 3000,
              readings: null,
            },
            {
              start: "2026-10-20T00:00:00+01:00",
              value: 3000,
              minimum: 3000,
              maximum: 3000,
              readings: null,
            },
            {
              start: "2026-10-21T00:00:00+01:00",
              value: 3500,
              minimum: 3500,
              maximum: 3500,
              readings: null,
            },
          ],
        },
      ],
      formulas: [],
      summary: { kind: "average", value: 9500 / 3, minimum: null, maximum: null },
      goal: null,
    });
  });

  it("filters by source and device model, the sample's own device or its provenance's", () => {
    const sql = makeStore();
    sql.exec(
      "INSERT INTO health_provenance (id, source_revision, device) VALUES (?, NULL, ?)",
      "0".repeat(32),
      JSON.stringify({ name: "Apple Watch", model: "Watch" }),
    );
    insertSample(sql, {
      type: heartRate,
      start: date(10, 20, 9),
      value: 60,
      provenance: "0".repeat(32),
    });
    insertSample(sql, {
      type: heartRate,
      start: date(10, 20, 10),
      value: 70,
      device: JSON.stringify({ model: "Watch" }),
    });
    insertSample(sql, {
      type: heartRate,
      start: date(10, 20, 11),
      value: 80,
      source: phone,
      device: JSON.stringify({ model: "iPhone" }),
    });
    // JSON that doesn't parse matches no model, rather than failing the card.
    insertSample(sql, { type: heartRate, start: date(10, 20, 12), value: 90, device: "{" });
    // A deleted sample the store hasn't swept yet.
    const deleted = insertSample(sql, { type: heartRate, start: date(10, 20, 13), value: 100 });
    sql.exec("INSERT INTO tombstones (entity, id, at) VALUES ('health_sample', ?, 0)", deleted);
    const maxOf = (filter: object | null) =>
      runCard(
        sql,
        spec({
          version: 1,
          display: { name: "HR" },
          series: [{ type: "Heart Rate", aggregation: "max", filter }],
          bucket: "day",
          range: "W",
        }),
        "W",
        date(10, 20),
        london,
        now,
      ).series[0]!.points.map((point) => [point.value, point.readings]);
    assert.deepStrictEqual(maxOf(null), [[90, 4]]);
    assert.deepStrictEqual(maxOf({ deviceModels: ["Watch"] }), [[70, 2]]);
    assert.deepStrictEqual(maxOf({ sources: [phone] }), [[80, 1]]);
    assert.deepStrictEqual(maxOf({ sources: [watch], deviceModels: ["iPhone"] }), []);
  });

  it("reads sample IDs for first's and latest's ties", () => {
    const sql = makeStore();
    const start = date(10, 20, 8);
    insertSample(sql, {
      type: heartRate,
      start,
      value: 71,
      id: "00000000-0000-4000-8000-00000000000c",
    });
    insertSample(sql, {
      type: heartRate,
      start,
      value: 72,
      id: "00000000-0000-4000-8000-00000000000a",
    });
    insertSample(sql, {
      type: heartRate,
      start,
      value: 73,
      id: "00000000-0000-4000-8000-00000000000b",
    });
    const value = (aggregation: string) =>
      runCard(
        sql,
        spec({
          version: 1,
          display: { name: "HR" },
          series: [{ type: "Heart Rate", aggregation }],
          bucket: "day",
        }),
        "W",
        date(10, 20),
        london,
        now,
      ).summary?.value;
    assert.strictEqual(value("first"), 72);
    assert.strictEqual(value("latest"), 71);
  });

  it("reads sleep windows' readings from their nights' stretches", () => {
    const sql = makeStore();
    for (const day of [20, 21]) {
      const midnight = date(10, day);
      // In bed from 22:30, asleep 23:00 to 01:00 and 01:10 to 06:30.
      insertSample(sql, {
        type: sleepType,
        start: midnight - 1.5 * hour,
        end: midnight + 7 * hour,
        categoryValue: 0,
      });
      insertSample(sql, {
        type: sleepType,
        start: midnight - hour,
        end: midnight + hour,
        categoryValue: 3,
      });
      insertSample(sql, {
        type: sleepType,
        start: midnight + hour,
        end: midnight + 70 * minute,
        categoryValue: 2,
      });
      insertSample(sql, {
        type: sleepType,
        start: midnight + 70 * minute,
        end: midnight + 6.5 * hour,
        categoryValue: 4,
      });
    }
    for (let at = date(10, 19, 20); at < date(10, 21, 12); at += 5 * minute) {
      insertSample(sql, { type: heartRate, start: at, value: 60 });
    }
    const card = spec({
      version: 1,
      display: { name: "Sleeping HR" },
      series: [{ type: "Heart Rate", aggregation: "count", window: { kind: "asleep" } }],
      bucket: "night",
      range: "W",
    });
    const data = runCard(sql, card, "W", date(10, 20), london, now);
    // 120 + 320 minutes asleep a night, a reading every 5.
    assert.deepStrictEqual(
      data.series[0]!.points.map((point) => [point.start, point.value]),
      [
        ["2026-10-20T00:00:00+01:00", 88],
        ["2026-10-21T00:00:00+01:00", 88],
      ],
    );
    assert.strictEqual(data.bucket, "night");
    assert.strictEqual(data.grain, "day");
  });

  it("reads workout windows' readings during the workouts", () => {
    const sql = makeStore();
    sql.exec(
      `INSERT INTO health_workout (id, activity_type, start_date, end_date, duration, activities,
        events, statistics, source_name, source_bundle_id)
      VALUES (?, 37, ?, ?, 1800, '[]', '[]', '{}', 'Synthetic', ?)`,
      nextId(),
      date(10, 20, 7),
      date(10, 20, 7, 30),
      watch,
    );
    for (let at = date(10, 20, 6); at < date(10, 20, 9); at += minute) {
      insertSample(sql, {
        type: heartRate,
        start: at,
        value: at < date(10, 20, 7, 30) && at >= date(10, 20, 7) ? 150 : 70,
      });
    }
    const card = spec({
      version: 1,
      display: { name: "Running HR" },
      series: [
        {
          type: "Heart Rate",
          aggregation: "min",
          window: { kind: "workout", activities: ["Running"] },
        },
      ],
      bucket: "day",
      range: "W",
    });
    assert.deepStrictEqual(
      runCard(sql, card, "W", date(10, 20), london, now).series[0]!.points.map((point) => [
        point.value,
        point.readings,
      ]),
      [[150, 30]],
    );
  });
});

describe("cardData", () => {
  it.effect("runs a card as a tool asks: its own range by default, today, in UTC", () =>
    Effect.gen(function* () {
      const sql = makeStore();
      insertSample(sql, { type: heartRate, start: Date.parse("2026-10-20T09:00:00Z"), value: 60 });
      yield* TestClock.setTime(Date.parse("2026-10-20T15:00:00Z"));
      const data = yield* cardData(sql, seed(1), {});
      assert.deepInclude(data, {
        range: "W",
        start: "2026-10-19",
        end: "2026-10-25",
        timeZone: "UTC",
        firstWeekday: "monday",
      });
      assert.strictEqual(data.series[0]!.points[0]!.start, "2026-10-20T00:00:00+00:00");
      const day = yield* cardData(sql, seed(1), {
        range: "D",
        date: "2026-10-20",
        timeZone: "America/New_York",
        firstWeekday: "sunday",
      });
      assert.deepInclude(day, {
        range: "D",
        start: "2026-10-20",
        end: "2026-10-20",
        grain: "hour",
      });
      assert.deepStrictEqual(
        day.series[0]!.points.map((point) => point.start),
        ["2026-10-20T05:00:00-04:00"],
      );
      const error = yield* Effect.flip(cardData(sql, seed(1), { timeZone: "Nowhere/Land" }));
      assert.instanceOf(error, HealthToolError);
      assert.include(error.message, "Unknown time zone");
      for (const date of ["2026-10", "2026-02-30", "yesterday"]) {
        const malformed = yield* Effect.flip(cardData(sql, seed(1), { date }));
        assert.instanceOf(malformed, HealthToolError);
        assert.include(malformed.message, "Unknown date");
      }
    }),
  );
});

describe("cardHeadline", () => {
  it("is a discrete type's latest reading, with the week ending on its day", () => {
    const sql = makeStore();
    insertSample(sql, { type: heartRate, start: date(10, 18, 9), value: 64 });
    insertSample(sql, { type: heartRate, start: date(10, 19, 9), value: 61 });
    // Not one dated ahead of now.
    insertSample(sql, { type: heartRate, start: date(10, 20, 18), value: 99 });
    const headline = cardHeadline(sql, seed(1), london, now);
    assert.deepInclude(headline, { value: 61, date: "2026-10-19T09:00:00+01:00", kind: "reading" });
    assert.deepInclude(headline?.data, {
      range: null,
      start: "2026-10-13",
      end: "2026-10-19",
      grain: "day",
    });
    assert.strictEqual(headline?.data.series[0]!.points.length, 2);
  });

  it("is a total's latest day with data, from its statistics or samples", () => {
    const sql = makeStore();
    insertStatistic(sql, steps, date(10, 18, 9), 2000);
    // An empty bucket sent ahead doesn't count.
    insertStatistic(sql, steps, date(10, 20, 9), 0);
    insertSample(sql, { type: steps, start: date(10, 19, 10), value: 300, source: phone });
    const headline = cardHeadline(sql, seed(0), london, now);
    assert.deepInclude(headline, { value: 300, date: "2026-10-19T00:00:00+01:00", kind: "bucket" });
  });

  it("searches back a week at a time for a filtered card, and is null without data", () => {
    const sql = makeStore();
    const card = {
      ...seed(1),
      series: [{ ...seed(1).series[0]!, filter: { sources: [watch], deviceModels: null } }],
    };
    assert.isNull(cardHeadline(sql, card, london, now));
    insertSample(sql, { type: heartRate, start: addDays(date(10, 20), -30) + 9 * hour, value: 58 });
    insertSample(sql, { type: heartRate, start: date(10, 19, 9), value: 70, source: phone });
    assert.deepInclude(cardHeadline(sql, card, london, now), {
      value: 58,
      date: "2026-09-20T00:00:00+01:00",
      kind: "bucket",
    });
  });
});
