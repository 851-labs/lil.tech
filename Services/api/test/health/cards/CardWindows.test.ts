import { assert, describe, it } from "@effect/vitest";
import {
  CardRun,
  type CardReading,
  latestOwnerWins,
} from "../../../src/health/cards/CardEngine.ts";
import {
  type CardSleepRecord,
  asleepStretches,
  cardNights,
  fallingAsleep,
  nightBedtime,
  nightRecordRange,
  waking,
} from "../../../src/health/cards/CardNights.ts";
import {
  addDays,
  date,
  heartRate,
  hour,
  london,
  minute,
  reading,
  restingHeartRate,
  run,
  spec,
} from "./CardEngineSupport.ts";

// Nights, sleep windows and workout windows in the server engine's core (851-3197), the Swift
// core's `CardWindowsTests` ported case for case, on the same synthetic sleep, workouts and
// readings in London.

const watch = "com.apple.health.watch";
const phone = "com.apple.health.phone";
const [inBed, asleep, awake, core, deep, rem] = [0, 1, 2, 3, 4, 5];

const record = (start: number, end: number, value: number, source = watch): CardSleepRecord => ({
  start,
  end,
  value,
  source,
});

/**
 * A Watch's night ending on `day` of October: in bed at 22:30 the evening before; Core from
 * 23:00, awake 01:00 to 01:10, Deep to 03:00, REM to 06:30, awake to 06:45, and in bed to 06:50.
 * `F` is 23:00, `W` 06:30.
 */
const watchNight = (day: number): Array<CardSleepRecord> => {
  const at = (hours: number) => date(10, day) + hours * hour;
  return [
    record(at(-1.5), at(6 + 50 / 60), inBed),
    record(at(-1), at(1), core),
    record(at(1), at(1 + 10 / 60), awake),
    record(at(1 + 10 / 60), at(3), deep),
    record(at(3), at(6.5), rem),
    record(at(6.5), at(6.75), awake),
  ];
};

/** A reading a minute over `[from, to)`, each a minute long, valued by `value`. */
const everyMinute = (
  from: number,
  to: number,
  value: (at: number) => number,
): Array<CardReading> => {
  const readings: Array<CardReading> = [];
  for (let at = from; at < to; at += minute)
    readings.push(reading(at, value(at), { source: watch }));
  return readings;
};

const windowCard = (
  series: ReadonlyArray<unknown>,
  bucket = "night",
  formulas: ReadonlyArray<unknown> = [],
) => spec({ version: 1, display: { name: "Card" }, series, formulas, bucket, range: "W" });

const values = (data: ReturnType<typeof run>) => data.series[0]!.points.map((point) => point.value);

describe("nights", () => {
  it("are Sleep's nights", () => {
    const records = [
      ...watchNight(20),
      // An iPhone's estimate of the same night, with less time asleep: another source.
      record(date(10, 19, 23, 30), date(10, 20, 5, 30), asleep, phone),
      // A nap that afternoon, 8 hours after waking: another session.
      record(date(10, 20, 15), date(10, 20, 16), core),
      // Only a day's sleep on Oct 22.
      record(date(10, 22, 13), date(10, 22, 14, 30), core),
    ].sort((a, b) => a.start - b.start);
    const nights = cardNights(records, { start: date(10, 19), end: date(10, 26) }, london);
    assert.deepStrictEqual(
      nights.map((night) => night.day),
      [date(10, 20), date(10, 22)],
    );
    const night = nights[0]!;
    assert.deepStrictEqual([...new Set(night.records.map((item) => item.source))], [watch]);
    assert.strictEqual(night.records.length, 5);
    assert.strictEqual(fallingAsleep(night), date(10, 19, 23));
    assert.strictEqual(waking(night), date(10, 20, 6, 30));
    assert.deepStrictEqual(asleepStretches(night), [
      { start: date(10, 19, 23), end: date(10, 20, 1) },
      { start: date(10, 20, 1, 10), end: date(10, 20, 6, 30) },
    ]);
    // In bed from 22:30 to 06:50.
    assert.strictEqual(night.inBed, (8 * 60 + 20) * minute);
    assert.strictEqual(nightBedtime(night, london), -1);
    // A day's sleep is a night of Sleep's page, but no night's sleep.
    assert.isUndefined(nightBedtime(nights[1]!, london));
    assert.deepStrictEqual(nightRecordRange({ start: date(10, 19), end: date(10, 26) }), {
      start: date(10, 18, 18),
      end: date(10, 25, 18),
    });
  });

  it("are the main session, with ties between sources to the bundle ID that sorts first", () => {
    const records = [
      // 30 minutes from 19:00, then 6 hours from 22:30: 3 hours apart, two sessions.
      record(date(10, 19, 19), date(10, 19, 19, 30), core, "b"),
      record(date(10, 19, 22, 30), date(10, 20, 4, 30), core, "b"),
      // As much sleep from another source that sorts after it.
      record(date(10, 19, 19), date(10, 19, 19, 30), asleep, "c"),
      record(date(10, 19, 22, 30), date(10, 20, 4, 30), asleep, "c"),
    ];
    const nights = cardNights(records, { start: date(10, 20), end: date(10, 21) }, london);
    assert.strictEqual(nights.length, 1);
    assert.deepStrictEqual(nights[0]!.records, [records[1]!]);
    assert.strictEqual(fallingAsleep(nights[0]!), date(10, 19, 22, 30));
  });

  it("without stages have their Asleep records as stretches asleep", () => {
    const sleep = [
      record(date(10, 19, 23, 30), date(10, 20, 2), asleep, phone),
      record(date(10, 20, 2), date(10, 20, 2, 20), awake, phone),
      record(date(10, 20, 2, 20), date(10, 20, 6), asleep, phone),
    ];
    const data = run(
      windowCard([{ type: "Heart Rate", aggregation: "count", window: { kind: "asleep" } }]),
      "W",
      date(10, 20),
      {
        readings: { [heartRate]: everyMinute(date(10, 19, 22), date(10, 20, 8), () => 60) },
        sleep,
      },
    );
    // 23:30 to 02:00 and 02:20 to 06:00: 150 and 220 minutes.
    assert.deepStrictEqual(values(data), [370]);
    assert.deepStrictEqual(
      data.series[0]!.points.map((point) => point.start),
      [date(10, 20)],
    );
  });
});

describe("the example cards", () => {
  it("chart heart rate while asleep, per night", () => {
    const card = spec({
      version: 1,
      display: { name: "Sleeping Heart Rate", symbol: "bed.double.fill", color: "indigo" },
      series: [{ type: "Heart Rate", window: { kind: "asleep" } }],
      bucket: "night",
      range: "W",
      chart: { style: "line" },
    });
    // Every 5 minutes: 50 in the first stretch asleep, 56 in the second, 70 awake in the night,
    // 80 up. The second night's 2 higher.
    const readings: Array<CardReading> = [];
    for (const [day, plus] of [
      [20, 0],
      [21, 2],
    ] as const) {
      for (let at = -120; at < 480; at += 5) {
        const value =
          at >= -60 && at < 60 ? 50 : at >= 60 && at < 70 ? 70 : at >= 70 && at < 390 ? 56 : 80;
        readings.push(reading(date(10, day) + at * minute, value + plus, { minutes: 0.5 }));
      }
    }
    const data = run(card, "W", date(10, 20), {
      readings: { [heartRate]: readings },
      sleep: [...watchNight(20), ...watchNight(21)],
    });
    const points = data.series[0]!.points;
    assert.deepStrictEqual(
      points.map((point) => point.start),
      [date(10, 20), date(10, 21)],
    );
    // 24 readings at 50 and 64 at 56, each 5 minutes, the last of each stretch to its end.
    assert.deepStrictEqual(
      points.map((point) => point.readings),
      [88, 88],
    );
    assert.isTrue(Math.abs(points[0]!.value - (24 * 50 + 64 * 56) / 88) < 1e-12);
    assert.isTrue(Math.abs(points[1]!.value - (24 * 52 + 64 * 58) / 88) < 1e-12);
    assert.deepInclude(points[0], { minimum: 50, maximum: 56 });
    assert.isTrue(
      Math.abs(data.summary!.value! - (points[0]!.value + points[1]!.value) / 2) < 1e-12,
    );
  });

  it("chart heart rate before falling asleep: a lone reading counts to the stretch's end", () => {
    const card = spec({
      version: 1,
      display: { name: "Before Sleep", symbol: "moon.zzz.fill", color: "indigo" },
      series: [{ type: "Heart Rate", window: { kind: "beforeSleep", minutes: 5 } }],
      bucket: "night",
      range: "W",
      chart: { style: "dots" },
    });
    // A reading a minute, from 60 at 22:55 up by one a minute.
    const readings = everyMinute(
      date(10, 19, 22),
      date(10, 20, 1),
      (at) => 60 + (at - date(10, 19, 22, 55)) / minute,
    );
    const data = run(card, "W", date(10, 20), {
      readings: { [heartRate]: readings },
      sleep: watchNight(20),
    });
    assert.deepStrictEqual(data.series[0]!.points, [
      { start: date(10, 20), value: 62, minimum: 60, maximum: 64, readings: 5 },
    ]);
    const lone = run(card, "W", date(10, 20), {
      readings: { [heartRate]: [reading(date(10, 19, 22, 56), 70), reading(date(10, 19, 23), 90)] },
      sleep: watchNight(20),
    });
    assert.deepStrictEqual(values(lone), [70]);

    // After waking: 06:30 to 07:00.
    const after = run(
      windowCard([
        { type: "Heart Rate", aggregation: "count", window: { kind: "afterWaking", minutes: 30 } },
      ]),
      "W",
      date(10, 20),
      {
        readings: {
          [heartRate]: [...readings, ...everyMinute(date(10, 20, 6), date(10, 20, 8), () => 70)],
        },
        sleep: watchNight(20),
      },
    );
    assert.deepStrictEqual(values(after), [30]);
  });
});

describe("edge cases", () => {
  for (const [month, day, hoursAsleep] of [
    [3, 29, 7],
    [10, 25, 9],
  ] as const) {
    it(`place nights over daylight saving (${month}/${day})`, () => {
      const evening = addDays(date(month, day), -1) + 23 * hour;
      const sleep = [record(evening, date(month, day, 7), core)];
      assert.strictEqual(date(month, day, 7) - evening, hoursAsleep * hour);
      const readings = everyMinute(evening - hour, date(month, day, 9), () => 60);
      const data = run(
        windowCard([{ type: "Heart Rate", aggregation: "count", window: { kind: "asleep" } }]),
        "W",
        date(month, day),
        { readings: { [heartRate]: readings }, sleep },
      );
      assert.deepStrictEqual(
        data.series[0]!.points.map((point) => point.start),
        [date(month, day)],
      );
      assert.deepStrictEqual(values(data), [hoursAsleep * 60]);
      const before = run(
        windowCard([
          {
            type: "Heart Rate",
            aggregation: "count",
            window: { kind: "beforeSleep", minutes: 90 },
          },
        ]),
        "W",
        date(month, day),
        { readings: { [heartRate]: readings }, sleep },
      );
      assert.deepStrictEqual(values(before), [60]);
    });
  }

  it("count a reading in two nights' stretches for the later", () => {
    const sleep = [
      // Oct 20's: from 10 AM (before noon, so a night's) to 8 PM.
      record(date(10, 20, 10), date(10, 20, 20), asleep, "com.example.a"),
      // Oct 21's, from 7 PM, another source.
      record(date(10, 20, 19), date(10, 21, 3), asleep, "com.example.b"),
    ];
    const readings = [
      reading(date(10, 20, 15), 60),
      reading(date(10, 20, 19, 30), 70),
      reading(date(10, 21, 2), 80),
    ];
    const data = run(
      windowCard([{ type: "Heart Rate", aggregation: "max", window: { kind: "asleep" } }]),
      "W",
      date(10, 20),
      { readings: { [heartRate]: readings }, sleep },
    );
    assert.deepStrictEqual(
      data.series[0]!.points.map((point) => [point.start, point.value, point.readings]),
      [
        [date(10, 20), 60, 1],
        [date(10, 21), 80, 2],
      ],
    );
    const resolved = latestOwnerWins([
      { stretch: { start: 0, end: 100 }, night: 0 },
      { stretch: { start: 50, end: 80 }, night: 1 },
      { stretch: { start: 90, end: 120 }, night: 1 },
    ]);
    assert.deepStrictEqual(
      resolved.map(({ stretch, night }) => [stretch.start, stretch.end, night]),
      [
        [0, 50, 0],
        [50, 80, 1],
        [80, 90, 0],
        [90, 120, 1],
      ],
    );
  });

  it("put a night's readings in the week of the day it ends on", () => {
    // Monday Oct 19's night starts on Sunday Oct 18.
    const sleep = [...watchNight(19), ...watchNight(20), ...watchNight(26)];
    const readings = everyMinute(date(10, 18, 20), date(10, 26, 12), () => 60);
    const card = spec({
      version: 1,
      display: { name: "Card" },
      series: [{ type: "Heart Rate", aggregation: "count", window: { kind: "asleep" } }],
      bucket: "week",
      range: "M",
    });
    const data = run(card, "M", date(10, 20), { readings: { [heartRate]: readings }, sleep });
    // 440 minutes asleep a night.
    assert.deepStrictEqual(
      data.series[0]!.points.map((point) => point.start),
      [date(10, 19), date(10, 26)],
    );
    assert.deepStrictEqual(values(data), [880, 440]);
  });

  it("bucket a series without a sleep window by the night's calendar day", () => {
    const card = windowCard(
      [
        { type: "Heart Rate", window: { kind: "asleep" }, hidden: true },
        { type: "Resting Heart Rate", hidden: true },
      ],
      "night",
      [{ id: "gap", kind: "difference", of: ["a", "b"] }],
    );
    const data = run(card, "W", date(10, 20), {
      readings: {
        [heartRate]: everyMinute(date(10, 19, 22), date(10, 20, 8), () => 58),
        [restingHeartRate]: [reading(date(10, 20, 9), 52)],
      },
      sleep: watchNight(20),
    });
    assert.deepStrictEqual(data.formulas[0]!.points, [{ start: date(10, 20), value: 6 }]);
  });

  it("read the nights before the period for a moving average of nights", () => {
    const card = windowCard(
      [{ type: "Heart Rate", aggregation: "count", window: { kind: "beforeSleep", minutes: 10 } }],
      "night",
      [{ id: "trend", kind: "movingAverage", of: "a", points: 3 }],
    );
    const cardRun = CardRun.forRange(card, "W", date(10, 20), date(10, 20), london);
    // Two nights before Monday Oct 19's.
    assert.deepStrictEqual(cardRun.windowFetches, [
      { _tag: "sleep", range: nightRecordRange({ start: date(10, 17), end: date(10, 26) }) },
    ]);
    // Its readings only once windowed.
    assert.deepStrictEqual(cardRun.fetches, []);
    assert.deepStrictEqual(cardRun.compute([]).series[0]!.points, []);
    const windowed = cardRun.windowed([
      { _tag: "sleep", records: [...watchNight(18), ...watchNight(19)] },
    ]);
    assert.deepStrictEqual(windowed.windowFetches, []);
    // Windowing it again changes nothing.
    assert.deepStrictEqual(windowed.windowed([]).fetches, windowed.fetches);
    assert.deepStrictEqual(
      windowed.fetches.map((item) => item.kind),
      [
        {
          _tag: "stretchReadings",
          stretches: [
            { start: date(10, 17, 22, 50), end: date(10, 17, 23) },
            { start: date(10, 18, 22, 50), end: date(10, 18, 23) },
          ],
          filter: null,
          needsSampleIds: false,
        },
      ],
    );
    const data = windowed.compute([
      {
        _tag: "readings",
        readings: [
          ...everyMinute(date(10, 17, 22, 50), date(10, 17, 23), () => 60),
          ...everyMinute(date(10, 18, 22, 54), date(10, 18, 23), () => 60),
        ],
      },
    ]);
    assert.deepStrictEqual(values(data), [6]);
    assert.deepStrictEqual(
      data.formulas[0]!.points.map((point) => point.value),
      [8],
    );
  });
});

describe("workouts", () => {
  const [running, cycling, walking] = [37, 13, 52];
  const workouts = [
    { start: date(10, 20, 7), end: date(10, 20, 7, 30), activityType: running },
    { start: date(10, 20, 18), end: date(10, 20, 19), activityType: cycling },
    // Two runs recorded over each other: 07:00 to 08:00.
    { start: date(10, 21, 7), end: date(10, 21, 7, 45), activityType: running },
    { start: date(10, 21, 7, 30), end: date(10, 21, 8), activityType: running },
    { start: date(10, 21, 12), end: date(10, 21, 12, 30), activityType: walking },
  ];

  it("keep readings during workouts of the activities given, overlapping ones merged", () => {
    const readings = everyMinute(date(10, 20, 6), date(10, 21, 20), (at) => {
      const workout = workouts.find((item) => at >= item.start && at < item.end);
      return workout === undefined ? 70 : workout.activityType === running ? 150 : 120;
    });
    const points = (activities: unknown) =>
      run(
        windowCard(
          [{ type: "Heart Rate", aggregation: "max", window: { kind: "workout", activities } }],
          "day",
        ),
        "W",
        date(10, 20),
        { readings: { [heartRate]: readings }, workouts },
      ).series[0]!.points.map((point) => [point.value, point.readings]);
    assert.deepStrictEqual(points([37]), [
      [150, 30],
      [150, 60],
    ]);
    assert.deepStrictEqual(points(["Cycling", "Walking"]), [
      [120, 60],
      [120, 30],
    ]);
    assert.deepStrictEqual(points(null), [
      [150, 90],
      [150, 90],
    ]);
    const workoutRun = CardRun.forRange(
      windowCard([{ type: "Heart Rate", window: { kind: "workout" } }], "day"),
      "W",
      date(10, 20),
      date(10, 20),
      london,
    );
    assert.deepStrictEqual(workoutRun.windowFetches, [
      { _tag: "workouts", range: { start: date(10, 19), end: date(10, 26) } },
    ]);
  });

  it("weigh a workout's last reading across the period's end as without the period", () => {
    const card = spec({
      version: 1,
      display: { name: "Card" },
      series: [{ type: "Heart Rate", window: { kind: "workout" } }],
      bucket: "hour",
      range: "D",
    });
    const day = CardRun.forRange(card, "D", date(10, 20), date(10, 20), london);
    const windowed = day.windowed([
      {
        _tag: "workouts",
        workouts: [
          { start: date(10, 20, 23, 30), end: date(10, 21, 0, 30), activityType: running },
        ],
      },
    ]);
    const readings = [
      reading(date(10, 20, 23, 30), 100),
      reading(date(10, 20, 23, 50), 160),
      reading(date(10, 21, 0, 10), 120),
    ];
    const data = windowed.compute(windowed.fetches.map(() => ({ _tag: "readings", readings })));
    // 100 for 20 minutes, 160 for 20, to the next reading past the period.
    assert.deepStrictEqual(values(data), [130]);
  });
});
