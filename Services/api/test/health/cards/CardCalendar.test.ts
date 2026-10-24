import { assert, describe, it } from "@effect/vitest";
import { DateTime, Effect, Exit } from "effect";
import {
  bucketStarts,
  cardCalendar,
  grainStart,
  rangeInterval,
  rangeIntervalContaining,
  rangeOffset,
  timeOfDayStretches,
} from "../../../src/health/cards/CardCalendar.ts";
import { date, hour, london, minute } from "./CardEngineSupport.ts";

// Periods, buckets and times of day for the server's card engine (851-3197), as Foundation's
// calendar gives them to the Swift core: in the call's time zone and first weekday, and over
// London's daylight saving changes.

describe("periods", () => {
  const now = date(10, 20, 15);

  it("are the calendar's day, week, month and year containing the date", () => {
    assert.deepStrictEqual(rangeIntervalContaining(london, "D", date(10, 20, 9), now), {
      start: date(10, 20),
      end: date(10, 21),
    });
    assert.deepStrictEqual(rangeIntervalContaining(london, "W", date(10, 25, 23), now), {
      start: date(10, 19),
      end: date(10, 26),
    });
    assert.deepStrictEqual(rangeIntervalContaining(london, "M", date(2, 14), now), {
      start: date(2, 1),
      end: date(3, 1),
    });
    assert.deepStrictEqual(rangeIntervalContaining(london, "Y", date(3, 1, 0, 0, 2025), now), {
      start: date(1, 1, 0, 0, 2025),
      end: date(1, 1),
    });
  });

  it("start weeks on the calendar's first weekday", () => {
    const sunday = { ...london, firstWeekday: "sunday" as const };
    assert.deepStrictEqual(rangeIntervalContaining(sunday, "W", date(10, 24), now), {
      start: date(10, 18),
      end: date(10, 25),
    });
    assert.deepStrictEqual(rangeIntervalContaining(sunday, "W", date(10, 25), now), {
      start: date(10, 25),
      end: date(11, 1),
    });
  });

  it("are six months ending with now's month, then the six before them, for 6M", () => {
    assert.deepStrictEqual(rangeInterval(london, "6M", 0, now), {
      start: date(5, 1),
      end: date(11, 1),
    });
    assert.deepStrictEqual(rangeInterval(london, "6M", -1, now), {
      start: date(11, 1, 0, 0, 2025),
      end: date(5, 1),
    });
    assert.strictEqual(rangeOffset(london, "6M", date(5, 1), now), 0);
    assert.strictEqual(rangeOffset(london, "6M", date(4, 30, 23), now), -1);
    assert.strictEqual(rangeOffset(london, "6M", date(11, 1), now), 1);
    assert.strictEqual(rangeOffset(london, "W", date(10, 4), now), -3);
    assert.strictEqual(rangeOffset(london, "D", date(3, 29, 12), now), -205);
  });

  it("count the hours of a day across a change of offset", () => {
    // London leaves summer time on Sunday 25 October 2026: 25 hours, starting at the first 1 AM.
    const hours = bucketStarts(london, "hour", date(10, 25), date(10, 26));
    assert.strictEqual(hours.length, 25);
    assert.strictEqual(hours[2]! - hours[1]!, hour);
    assert.strictEqual(bucketStarts(london, "hour", date(3, 29), date(3, 30)).length, 23);
    assert.strictEqual(grainStart(london, "day", date(10, 25, 23, 59)), date(10, 25));
  });

  it("come from a time zone and first weekday a call names", () => {
    const calendar = Effect.runSync(cardCalendar("America/New_York", "sunday"));
    assert.strictEqual(calendar.timeZone, "America/New_York");
    assert.strictEqual(calendar.firstWeekday, "sunday");
    const utc = Effect.runSync(cardCalendar(undefined, undefined));
    assert.deepInclude(utc, { timeZone: "UTC", firstWeekday: "monday" });
    assert.isTrue(Exit.isFailure(Effect.runSyncExit(cardCalendar("Mars/Olympus", undefined))));
  });
});

describe("times of day", () => {
  const window = (from: string, to: string) => ({ from, to });

  it("are each day's hours on the clock", () => {
    assert.deepStrictEqual(
      timeOfDayStretches(
        window("00:00", "12:00"),
        { start: date(1, 10), end: date(1, 12) },
        london.zone,
      ),
      [
        { start: date(1, 10), end: date(1, 10, 12) },
        { start: date(1, 11), end: date(1, 11, 12) },
      ],
    );
  });

  it("can cross midnight", () => {
    assert.deepStrictEqual(
      timeOfDayStretches(
        window("22:00", "06:00"),
        { start: date(1, 10), end: date(1, 12) },
        london.zone,
      ),
      [
        { start: date(1, 10), end: date(1, 10, 6) },
        { start: date(1, 10, 22), end: date(1, 11, 6) },
        { start: date(1, 11, 22), end: date(1, 12) },
      ],
    );
  });

  it("follow the clock over daylight saving", () => {
    const spring = { start: date(3, 29), end: date(3, 30) };
    // The day clocks go forward has no 1 AM hour, and the day they go back has two.
    assert.deepStrictEqual(timeOfDayStretches(window("01:00", "02:00"), spring, london.zone), []);
    const autumn = timeOfDayStretches(
      window("01:00", "02:00"),
      { start: date(10, 25), end: date(10, 26) },
      london.zone,
    );
    assert.deepStrictEqual(
      autumn.map(({ start, end }) => (end - start) / minute),
      [120],
    );
    const short = timeOfDayStretches(window("00:00", "12:00"), spring, london.zone);
    assert.deepStrictEqual(
      short.map(({ start, end }) => (end - start) / hour),
      [11],
    );
  });

  for (const [from, to] of [
    ["01:00", "02:00"],
    ["22:00", "06:00"],
    ["00:30", "01:30"],
    ["07:00", "23:59"],
  ] as const) {
    it(`keep exactly the readings the clock rule keeps (${from} to ${to})`, () => {
      const fromSeconds = Number(from.slice(0, 2)) * 3600 + Number(from.slice(3)) * 60;
      const toSeconds = Number(to.slice(0, 2)) * 3600 + Number(to.slice(3)) * 60;
      const contains = (seconds: number) =>
        fromSeconds < toSeconds
          ? fromSeconds <= seconds && seconds < toSeconds
          : seconds >= fromSeconds || seconds < toSeconds;
      for (const [start, end] of [
        [date(3, 28), date(3, 31)],
        [date(10, 24), date(10, 27)],
      ] as const) {
        const stretches = timeOfDayStretches(window(from, to), { start, end }, london.zone);
        for (let moment = start; moment < end; moment += 7 * minute + 13) {
          const parts = DateTime.toParts(
            DateTime.makeZonedUnsafe(moment, { timeZone: london.zone }),
          );
          const seconds =
            parts.hour * 3600 + parts.minute * 60 + parts.second + parts.millisecond / 1000;
          const inStretch = stretches.some(
            (stretch) => stretch.start <= moment && moment < stretch.end,
          );
          assert.strictEqual(
            inStretch,
            contains(seconds),
            `${from}–${to} at ${new Date(moment).toISOString()}`,
          );
        }
      }
    });
  }
});
