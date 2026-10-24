import { assert, describe, it } from "@effect/vitest";
import { DateTime, Schema } from "effect";
import {
  CardRun,
  type CardTotal,
  cardWeights,
  cardWindowWeights,
  headlineLookup,
  headlineSearchEnds,
  leadPoints,
  readingsInStretches,
} from "../../../src/health/cards/CardEngine.ts";
import { CardSpec } from "../../../src/health/cards/CardSpec.ts";
import { welcomeSeed } from "../../../src/health/cards/WelcomeSeed.ts";
import {
  addDays,
  bodyMass,
  bodyTemperature,
  date,
  fetch,
  heartRate,
  hour,
  hrv,
  london,
  reading,
  restingHeartRate,
  run,
  spec,
  steps,
} from "./CardEngineSupport.ts";

// The server engine's core on synthetic readings (851-3197), the Swift core's `CardEngineTests`
// ported case for case, with the same data and the same answers: the Mac and the server must
// match. 851-3198's conformance cases then check both on one dataset. Synthetic data only.

const seed = (index: number) => Schema.decodeUnknownSync(CardSpec)(welcomeSeed[index]!.spec);

const close = (actual: number | null | undefined, expected: number, tolerance = 1e-9) =>
  assert.isTrue(
    actual !== null && actual !== undefined && Math.abs(actual - expected) <= tolerance,
    `${actual} ≉ ${expected}`,
  );

describe("weights", () => {
  it("time-weighted readings count until their source's next, or for their duration", () => {
    const readings = [
      { start: 0, end: 10_000, value: 60, source: "watch", sampleId: "" },
      { start: 30_000, end: 31_000, value: 70, source: "phone", sampleId: "" },
      { start: 60_000, end: 61_000, value: 80, source: "watch", sampleId: "" },
      // Its last: its own duration, at least a second.
      { start: 120_000, end: 120_200, value: 90, source: "watch", sampleId: "" },
    ];
    assert.deepStrictEqual(
      [...cardWeights(readings, "discreteTemporallyWeighted")],
      [60, 1, 60, 1],
    );
    assert.deepStrictEqual([...cardWeights(readings, "discreteArithmetic")], [1, 1, 1, 1]);
  });

  it("in a window, each stretch is on its own", () => {
    const stretches = [
      { start: 0, end: 300_000 },
      { start: 1_000_000, end: 9_000_000 },
    ];
    const readings = [0, 60_000, 200_000, 1_000_000].map((start, index) => ({
      start,
      end: start + 1000,
      value: 60 + 2 * index,
      source: "watch",
      sampleId: "",
    }));
    const weights = cardWindowWeights(
      readings,
      stretches,
      [0, 0, 0, 1],
      "discreteTemporallyWeighted",
    );
    assert.deepStrictEqual([...weights], [60, 140, 100, 3600]);
  });

  it("keeps readings in a window by their start", () => {
    const readings = [5, 10, 19, 20, 35, 40].map((start) => ({
      start,
      end: start + 100,
      value: 1,
      source: "s",
      sampleId: "",
    }));
    const kept = readingsInStretches(readings, [
      { start: 10, end: 20 },
      { start: 30, end: 40 },
    ]);
    assert.deepStrictEqual(
      kept.readings.map((item) => item.start),
      [10, 19, 35],
    );
    assert.deepStrictEqual(kept.stretchIndices, [0, 0, 1]);
  });
});

describe("aggregations and buckets", () => {
  const weightCard = (aggregation: string, bucket = "day", range = "W") =>
    spec({
      version: 1,
      display: { name: "W" },
      series: [{ type: "Weight", aggregation }],
      bucket,
      range,
      chart: { style: "dots" },
    });

  for (const [aggregation, value] of [
    ["avg", 3],
    ["min", 1],
    ["max", 5],
    ["first", 3],
    ["latest", 5],
    ["count", 3],
  ] as const) {
    it(`gives a day's ${aggregation}`, () => {
      const readings = [
        reading(date(10, 20, 9), 3),
        reading(date(10, 20, 10), 1),
        reading(date(10, 20, 11), 5),
      ];
      const data = run(weightCard(aggregation), "W", date(10, 20), {
        readings: { [bodyMass]: readings },
      });
      assert.strictEqual(data.series[0]!.points.length, 1);
      const point = data.series[0]!.points[0]!;
      assert.strictEqual(point.start, date(10, 20));
      assert.strictEqual(point.value, value);
      assert.strictEqual(point.readings, 3);
      if (aggregation === "count") {
        assert.deepInclude(point, { minimum: 3, maximum: 3 });
        assert.strictEqual(data.series[0]!.unit, "count");
      } else {
        assert.deepInclude(point, { minimum: 1, maximum: 5 });
        assert.strictEqual(data.series[0]!.unit, "kg");
      }
    });
  }

  it("breaks first's and latest's ties by end, then sample ID", () => {
    const readings = [
      reading(date(10, 20, 8), 70, { minutes: 2, id: "b" }),
      reading(date(10, 20, 8), 71, { minutes: 1, id: "c" }),
      reading(date(10, 20, 8), 72, { minutes: 1, id: "a" }),
      reading(date(10, 20, 20), 80, { minutes: 1, id: "a" }),
      reading(date(10, 20, 20), 81, { minutes: 1, id: "b" }),
    ];
    const first = run(weightCard("first"), "W", date(10, 20), {
      readings: { [bodyMass]: readings },
    });
    assert.deepStrictEqual(
      first.series[0]!.points.map((point) => point.value),
      [72],
    );
    assert.deepStrictEqual(first.summary, {
      kind: "first",
      value: 72,
      minimum: null,
      maximum: null,
    });
    const latest = run(weightCard("latest"), "W", date(10, 20), {
      readings: { [bodyMass]: readings },
    });
    assert.deepStrictEqual(
      latest.series[0]!.points.map((point) => point.value),
      [81],
    );
    assert.deepStrictEqual(latest.summary, {
      kind: "latest",
      value: 81,
      minimum: null,
      maximum: null,
    });
  });

  it("follows the calendar", () => {
    const readings = Array.from({ length: 120 }, (_, index) =>
      reading(date(9, 1) + index * 24 * hour + hour, 70),
    );
    const data = { readings: { [bodyMass]: readings } };
    // auto: hours at D, days at W and M, weeks at 6M, months at Y.
    const auto = weightCard("avg", "auto");
    assert.strictEqual(run(auto, "D", date(10, 20), data).grain, "hour");
    assert.deepStrictEqual(
      run(auto, "W", date(10, 20), data).series[0]!.points.map((point) => point.start),
      [19, 20, 21, 22, 23, 24, 25].map((day) => date(10, day)),
    );
    assert.deepStrictEqual(
      run(auto, "Y", date(10, 20), data).series[0]!.points.map((point) => point.start),
      [9, 10, 11, 12].map((month) => date(month, 1)),
    );
    // A week at M starts on the calendar's first weekday, before the month, and counts only the
    // month's readings.
    const weeks = run(weightCard("count", "week", "M"), "M", date(10, 20), data);
    assert.strictEqual(weeks.series[0]!.points[0]!.start, date(9, 28));
    assert.strictEqual(weeks.series[0]!.points[0]!.value, 4);
    assert.strictEqual(
      weeks.series[0]!.points.reduce((sum, point) => sum + point.value, 0),
      31,
    );
  });
});

describe("totals", () => {
  /** 100 steps an hour from 8 AM to 6 PM, every day but Sundays. */
  const hourlySteps: Array<CardTotal> = Array.from({ length: 400 }, (_, day) =>
    addDays(date(1, 1), day),
  )
    .filter(
      (start) =>
        DateTime.getPart(DateTime.makeZonedUnsafe(start, { timeZone: london.zone }), "weekDay") !==
        0,
    )
    .flatMap((start) =>
      Array.from({ length: 10 }, (_, index) => ({ start: start + (8 + index) * hour, sum: 100 })),
    );
  // Hours from midnight are the clock's but on the two days of a change, which are Sundays.
  const totals = { hourlyTotals: { [steps]: hourlySteps } };

  it("chart as Metric Detail", () => {
    const day = run(seed(0), "D", date(10, 20), totals);
    assert.strictEqual(day.grain, "hour");
    assert.strictEqual(day.series[0]!.points.length, 10);
    assert.isNull(day.series[0]!.points[0]!.readings);
    assert.deepStrictEqual(day.summary, {
      kind: "total",
      value: 1000,
      minimum: null,
      maximum: null,
    });
    // A week: a day's total each, and its average day with steps.
    const week = run(seed(0), "W", date(10, 20), totals);
    assert.deepStrictEqual(
      week.series[0]!.points.map((point) => point.value),
      [1000, 1000, 1000, 1000, 1000, 1000],
    );
    assert.deepStrictEqual(week.summary, {
      kind: "average",
      value: 1000,
      minimum: null,
      maximum: null,
    });
    // 6M: each week's average day, captioned DAILY AVERAGE.
    const sixMonths = run(seed(0), "6M", date(10, 20), totals);
    assert.strictEqual(sixMonths.grain, "week");
    assert.isTrue(sixMonths.series[0]!.points.every((point) => point.value === 1000));
    assert.deepStrictEqual(sixMonths.summary, {
      kind: "dailyAverage",
      value: 1000,
      minimum: null,
      maximum: null,
    });
  });

  it("total each bucket of a fixed bucket", () => {
    const card = { ...seed(0), bucket: "week" as const, range: "M" as const };
    const data = run(card, "M", date(10, 20), totals);
    // Oct 2026's weeks from Monday Sep 28: its first has Oct 1–3, three days.
    assert.deepStrictEqual(data.series[0]!.points[0], {
      start: date(9, 28),
      value: 3000,
      minimum: 3000,
      maximum: 3000,
      readings: null,
    });
    assert.deepStrictEqual(
      data.series[0]!.points.map((point) => point.start),
      [date(9, 28), date(10, 5), date(10, 12), date(10, 19), date(10, 26)],
    );
    assert.deepStrictEqual(data.summary, {
      kind: "average",
      value: 27_000 / 5,
      minimum: null,
      maximum: null,
    });
  });

  it("fetch the buckets before the period for a moving average", () => {
    const card = {
      ...seed(0),
      formulas: [
        {
          id: "trend",
          kind: "movingAverage" as const,
          of: "a",
          points: 3,
          label: null,
          hidden: false,
        },
      ],
    };
    const cardRun = CardRun.forRange(card, "6M", date(10, 20), date(10, 20), london);
    // 6M from May 1 (a Friday): its first week starts Monday Apr 27, two weeks after Apr 13.
    assert.deepStrictEqual(
      cardRun.fetches.map((item) => item.kind),
      [
        { _tag: "totals", range: { start: date(5, 1), end: date(11, 1) }, grain: "day" },
        { _tag: "totals", range: { start: date(4, 13), end: date(4, 27) }, grain: "day" },
      ],
    );
  });
});

describe("formulas and summaries", () => {
  it("chart morning weight: the first weigh-in before noon, and its 7-day rolling average", () => {
    const card = spec({
      version: 1,
      display: { name: "Morning Weight", symbol: "scalemass.fill", color: "purple" },
      series: [
        {
          type: "Weight",
          aggregation: "first",
          window: { kind: "timeOfDay", from: "00:00", to: "12:00" },
          label: "First weigh-in before noon",
        },
      ],
      formulas: [
        { id: "trend", kind: "movingAverage", of: "a", points: 7, label: "7-day rolling average" },
      ],
      bucket: "day",
      range: "M",
      chart: { style: "dots" },
    });
    // From Sep 25: a weigh-in at 7:30, another at 8:00 and one in the evening, but on Oct 5 only
    // after noon.
    const readings = Array.from({ length: 20 }, (_, offset) => {
      const day = addDays(date(9, 25), offset);
      const morning = 70 + offset / 10;
      if (day === date(10, 5)) return [reading(day + 13 * hour, 90)];
      return [
        reading(day + 7.5 * hour, morning),
        reading(day + 8 * hour, morning + 1),
        reading(day + 19 * hour, morning + 5),
      ];
    }).flat();
    const data = run(card, "M", date(10, 20), { readings: { [bodyMass]: readings } });
    const series = data.series[0]!;
    assert.strictEqual(series.label, "First weigh-in before noon");
    assert.notInclude(
      series.points.map((point) => point.start),
      date(10, 5),
    );
    assert.strictEqual(series.points[0]!.start, date(10, 1));
    assert.strictEqual(series.points[0]!.value, 70.6);
    assert.strictEqual(series.points.length, 13);
    // Oct 1's average reaches back to Sep 25: 70.0 to 70.6.
    const trend = data.formulas[0]!;
    assert.strictEqual(trend.label, "7-day rolling average");
    assert.strictEqual(trend.points.length, series.points.length);
    close(trend.points[0]!.value, 70.3);
    // Oct 8's window is Oct 2–8, without Oct 5.
    close(
      trend.points.find((point) => point.start === date(10, 8))?.value,
      (70.7 + 70.8 + 70.9 + 71.1 + 71.2 + 71.3) / 6,
    );
    assert.deepStrictEqual(data.summary, {
      kind: "first",
      value: 70.6,
      minimum: null,
      maximum: null,
    });
  });

  it("chart body temperature, and HRV's dots with a 7-point moving average", () => {
    const temperature = spec({
      version: 1,
      display: { name: "Body Temperature", symbol: "thermometer.medium", color: "red" },
      series: [{ type: "BodyTemperature" }],
      range: "M",
      chart: { style: "line" },
    });
    const temperatures = Array.from({ length: 10 }, (_, index) =>
      reading(date(10, index + 1, 7), 36.5 + ((index + 1) % 3) / 10),
    );
    const data = run(temperature, "M", date(10, 20), {
      readings: { [bodyTemperature]: temperatures },
    });
    assert.strictEqual(data.series[0]!.points.length, 10);
    assert.strictEqual(data.series[0]!.unit, "degC");
    close(data.summary?.value, temperatures.reduce((sum, item) => sum + item.value, 0) / 10, 1e-12);

    const hrvCard = spec({
      version: 1,
      display: { name: "HRV", symbol: "waveform.path.ecg", color: "pink" },
      series: [{ type: "HeartRateVariabilitySDNN" }],
      formulas: [{ id: "trend", kind: "movingAverage", of: "a", points: 7 }],
      range: "M",
      chart: { style: "dots" },
    });
    const hrvs = Array.from({ length: 40 }, (_, index) =>
      reading(date(9, 10) + index * 24 * hour + 6 * hour, 40 + index),
    );
    const hrvData = run(hrvCard, "M", date(10, 20), { readings: { [hrv]: hrvs } });
    // Oct 1 is day 21: its average is days 15 to 21.
    assert.deepStrictEqual(hrvData.formulas[0]!.points[0], { start: date(10, 1), value: 58 });
    assert.strictEqual(hrvData.formulas[0]!.points.length, 19);
  });

  it("give a ranges card's header as its range, or its average", () => {
    const readings = [reading(date(10, 20, 9), 60), reading(date(10, 21, 9), 90)];
    const data = run(seed(1), "W", date(10, 20), { readings: { [heartRate]: readings } });
    assert.deepStrictEqual(data.summary, { kind: "range", value: null, minimum: 60, maximum: 90 });
    const same = run(seed(1), "W", date(10, 20), { readings: { [heartRate]: [readings[0]!] } });
    assert.deepStrictEqual(same.summary, {
      kind: "average",
      value: 60,
      minimum: null,
      maximum: null,
    });
    assert.isNull(run(seed(1), "W", date(9, 1), { readings: { [heartRate]: readings } }).summary);
  });

  it("chart a difference of hidden series, the formula the lead", () => {
    const card = spec({
      version: 1,
      display: { name: "Gap" },
      series: [
        { type: "Heart Rate", hidden: true },
        { type: "Resting Heart Rate", hidden: true },
      ],
      formulas: [{ id: "gap", kind: "difference", of: ["a", "b"] }],
      bucket: "day",
      range: "W",
      chart: { style: "line" },
    });
    const data = run(card, "W", date(10, 20), {
      readings: {
        [heartRate]: [reading(date(10, 20, 9), 70), reading(date(10, 21, 9), 75)],
        [restingHeartRate]: [reading(date(10, 20, 6), 55)],
      },
    });
    assert.deepStrictEqual(data.formulas[0]!.points, [{ start: date(10, 20), value: 15 }]);
    assert.deepStrictEqual(data.summary, {
      kind: "average",
      value: 15,
      minimum: null,
      maximum: null,
    });
    assert.deepStrictEqual(leadPoints(data), data.formulas[0]!.points);
  });
});

describe("fetches", () => {
  it("reach an hour past the period for time weighting", () => {
    const cardRun = CardRun.forRange(seed(1), "D", date(10, 20, 12), date(10, 20, 12), london);
    assert.deepStrictEqual(cardRun.fetches, [
      {
        series: 0,
        type: heartRate,
        purpose: "period",
        kind: {
          _tag: "readings",
          range: { start: date(10, 20), end: date(10, 21) + hour },
          filter: null,
          needsSampleIds: false,
        },
      },
    ]);
  });
});

describe("headlines", () => {
  it("are found as Summary finds them", () => {
    assert.deepStrictEqual(headlineLookup(seed(0)), { _tag: "latestData", type: steps });
    assert.deepStrictEqual(headlineLookup(seed(1)), { _tag: "latestReading", type: heartRate });
    assert.deepStrictEqual(headlineLookup(seed(5)), { _tag: "latestReading", type: bodyMass });
    const filtered = {
      ...seed(1),
      series: [{ ...seed(1).series[0]!, filter: { sources: null, deviceModels: ["Watch"] } }],
    };
    assert.deepStrictEqual(headlineLookup(filtered), { _tag: "search" });
    const ends = headlineSearchEnds(filtered, date(10, 20, 9), london);
    assert.strictEqual(ends.length, 8);
    assert.strictEqual(ends[1], date(10, 13));
    assert.strictEqual(ends[7], date(9, 1));
  });

  it("run the seven buckets ending on them", () => {
    const cardRun = CardRun.forHeadline(seed(0), date(10, 20, 9), london);
    assert.strictEqual(cardRun.grain, "day");
    assert.deepStrictEqual(cardRun.interval, { start: date(10, 14), end: date(10, 21) });
    const hourlySteps = Array.from({ length: 7 }, (_, day) => addDays(date(10, 14), day))
      .filter((start) => start !== date(10, 18))
      .map((start) => ({ start: start + 9 * hour, sum: 1000 }));
    const data = cardRun.compute(fetch(cardRun, { hourlyTotals: { [steps]: hourlySteps } }));
    assert.deepStrictEqual(leadPoints(data).at(-1), { start: date(10, 20), value: 1000 });
    assert.strictEqual(data.series[0]!.points.length, 6);
  });
});
