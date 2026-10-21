import { assert, describe, it } from "@effect/vitest";
import { DateTime, Exit, Option, Schema } from "effect";
import {
  statisticsSource,
  statisticsSourceStalenessMillis,
} from "../../../src/health/tools/HealthQueries.ts";
import { HealthToolkit } from "../../../src/health/tools/HealthToolkit.ts";
import {
  bucketIndex,
  localDate,
  localTime,
  startOfDay,
  startOfHour,
  toolPeriod,
} from "../../../src/health/tools/ToolTime.ts";

const day = 24 * 60 * 60 * 1000;
const now = Date.parse("2026-10-20T15:00:00Z");
const device = (name: string, pairedWithWatch: boolean, reportedAt: number) => ({
  device: name,
  pairedWithWatch,
  reportedAt,
});

describe("statisticsSource", () => {
  it("is nobody without iPhones", () => {
    assert.isNull(statisticsSource([], now));
  });

  it("prefers a recent iPhone paired with a Watch, then the most recent", () => {
    const paired = device("dev_a", true, now - 3 * day);
    const recent = device("dev_b", false, now - day);
    assert.strictEqual(statisticsSource([recent, paired], now), "dev_a");
    assert.strictEqual(
      statisticsSource([recent, device("dev_c", false, now - 2 * day)], now),
      "dev_b",
    );
  });

  it("skips a paired iPhone that hasn't reported for 14 days", () => {
    const stale = device("dev_a", true, now - statisticsSourceStalenessMillis - 1);
    assert.strictEqual(statisticsSource([stale, device("dev_b", false, now - day)], now), "dev_b");
  });

  it("takes the most recent of all when none reported recently, ignoring Watches", () => {
    const old = now - 30 * day;
    assert.strictEqual(
      statisticsSource([device("dev_a", true, old), device("dev_b", false, old + 1)], now),
      "dev_b",
    );
  });

  it("breaks ties with the higher device ID", () => {
    assert.strictEqual(
      statisticsSource([device("dev_b", true, now), device("dev_a", true, now)], now),
      "dev_b",
    );
  });
});

describe("tool times", () => {
  const london = Option.getOrThrow(DateTime.zoneMakeNamed("Europe/London"));

  it("are local, to the second, with the offset", () => {
    const millis = Date.parse("2026-10-20T14:45:30.750Z");
    assert.strictEqual(localTime(millis, london), "2026-10-20T15:45:30+01:00");
    assert.strictEqual(
      localTime(millis, Option.getOrThrow(DateTime.zoneMakeNamed("UTC"))),
      "2026-10-20T14:45:30+00:00",
    );
    assert.strictEqual(localDate(Date.parse("2026-10-19T23:30:00Z"), london), "2026-10-20");
  });

  it("count days across a change of offset", () => {
    // London leaves summer time on Sunday 25 October 2026, so that day has 25 hours.
    const sunday = Date.parse("2026-10-25T12:00:00Z");
    assert.strictEqual(startOfDay(sunday, london), Date.parse("2026-10-24T23:00:00Z"));
    assert.strictEqual(startOfDay(sunday, london, 1), Date.parse("2026-10-26T00:00:00Z"));
    assert.strictEqual(startOfDay(sunday, london, -6), Date.parse("2026-10-18T23:00:00Z"));
  });
});

describe("tool periods", () => {
  const london = Option.getOrThrow(DateTime.zoneMakeNamed("Europe/London"));
  const kolkata = Option.getOrThrow(DateTime.zoneMakeNamed("Asia/Kolkata"));
  const times = (millis: ReadonlyArray<number>) => millis.map((time) => localTime(time, london));

  it("have 25 hours on the day London leaves summer time", () => {
    const period = toolPeriod("D", "2026-10-25", now, london);
    assert.strictEqual(period.buckets.length, 25);
    assert.deepStrictEqual(times(period.buckets.slice(0, 3)), [
      "2026-10-25T00:00:00+01:00",
      "2026-10-25T01:00:00+01:00",
      "2026-10-25T01:00:00+00:00",
    ]);
    assert.strictEqual(localTime(period.end, london), "2026-10-26T00:00:00+00:00");
  });

  it("count 26 weeks for 6M, and 12 calendar months for Y", () => {
    const sixMonths = toolPeriod("6M", "2026-10-20", now, london);
    assert.strictEqual(sixMonths.buckets.length, 26);
    assert.strictEqual(localTime(sixMonths.start, london), "2026-04-22T00:00:00+01:00");
    const year = toolPeriod("Y", undefined, now, london);
    assert.deepStrictEqual(times([year.start, year.buckets[11]!, year.end]), [
      "2025-11-01T00:00:00+00:00",
      "2026-10-01T00:00:00+01:00",
      "2026-10-21T00:00:00+01:00",
    ]);
  });

  it("place a time in its bucket", () => {
    const week = toolPeriod("W", "2026-10-20", now, london);
    assert.strictEqual(bucketIndex(week, week.start), 0);
    assert.strictEqual(bucketIndex(week, week.end - 1), 6);
    assert.isUndefined(bucketIndex(week, week.end));
    assert.isUndefined(bucketIndex(week, week.start - 1));
  });

  it("start hours at local hours, in half-hour zones too", () => {
    const millis = Date.parse("2026-10-20T08:10:00Z");
    assert.strictEqual(startOfHour(millis, kolkata), Date.parse("2026-10-20T07:30:00Z"));
    assert.strictEqual(startOfHour(millis, london), Date.parse("2026-10-20T08:00:00Z"));
  });
});

describe("the toolkit's dates", () => {
  const decode = Schema.decodeUnknownExit(HealthToolkit.tools.metric.parametersSchema);
  const call = (date: string) => ({ type: "HKQuantityTypeIdentifierStepCount", range: "W", date });

  it("are days that exist", () => {
    assert.isTrue(Exit.isSuccess(decode(call("2028-02-29"))));
    assert.isTrue(Exit.isFailure(decode(call("2026-02-29"))));
    assert.isTrue(Exit.isFailure(decode(call("2026-13-01"))));
    assert.isTrue(Exit.isFailure(decode(call("20261020"))));
  });
});
