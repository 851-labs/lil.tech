import { assert, describe, it } from "@effect/vitest";
import { DateTime, Option } from "effect";
import {
  statisticsSource,
  statisticsSourceStalenessMillis,
} from "../../../src/health/tools/HealthQueries.ts";
import { localDate, localTime, startOfDay } from "../../../src/health/tools/ToolTime.ts";

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
