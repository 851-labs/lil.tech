import { assert, describe, it } from "@effect/vitest";
import { DateTime, Option } from "effect";
import type { CardCalendar } from "../../../src/health/cards/CardCalendar.ts";
import {
  type CardSleepRecord,
  cardNights,
  fallingAsleep,
  nightBedtime,
  nightClock,
  nightRecordRange,
  sleepRunZones,
  waking,
} from "../../../src/health/cards/CardNights.ts";
import { cardSleepRecords } from "../../../src/health/cards/CardQueries.ts";
import { namedTimeZone, startOfLocalDay } from "../../../src/health/tools/ToolTime.ts";
import { migrate } from "../../../src/store/Migrations.ts";
import { makeTestStoreSql } from "../../store/TestStoreSql.ts";

// Nights in the zone their records were recorded in (851-4175, docs/decisions/cards.md ›
// Recorded time zones), on a synthetic trip in June 2025, as the conformance cases' dataset has
// it: the Swift core's `CardNightZonesTests` (851-4174), case for case.

const watch = "com.apple.health.watch";
const [inBed, asleep, awake, core, deep, rem] = [0, 1, 2, 3, 4, 5];
const tokyo = "Asia/Tokyo";
const newYork = "America/New_York";
const londonZone = "Europe/London";

const calendar = (zone: string): CardCalendar => ({
  zone: Option.getOrThrow(DateTime.zoneMakeNamed(zone)),
  timeZone: zone,
  firstWeekday: "monday",
});

/** A UTC time in June 2025. */
const utc = (day: number, hour: number, minute = 0) => Date.UTC(2025, 5, day, hour, minute);

/** The start of a day of June 2025 in `calendar`. */
const day = (date: number, calendar: CardCalendar) =>
  startOfLocalDay(`2025-06-${String(date).padStart(2, "0")}`, calendar.zone);

const record = (
  start: number,
  end: number,
  value: number,
  timeZone: string | undefined,
  source = watch,
): CardSleepRecord => ({ start, end, value, source, ...(timeZone !== undefined && { timeZone }) });

const withoutZones = (records: ReadonlyArray<CardSleepRecord>) =>
  records.map(({ start, end, value, source }) => ({ start, end, value, source }));

/**
 * The Watch's night in Tokyo: 23:00 JST on 11 June to 06:30 JST on the 12th (14:00Z to 21:30Z),
 * 15:00 to 22:30 on London's clock.
 */
const tokyoNight = [
  record(utc(11, 13, 45), utc(11, 21, 40), inBed, tokyo),
  record(utc(11, 14), utc(11, 17, 30), core, tokyo),
  record(utc(11, 17, 30), utc(11, 17, 45), awake, tokyo),
  record(utc(11, 17, 45), utc(11, 21, 30), rem, tokyo),
];

describe("zone names", () => {
  // IANA names, and the old aliases Apple may write (`TimeZone.current.identifier`), are zones.
  it.each([
    "Asia/Kolkata",
    "Asia/Calcutta",
    "Europe/Kyiv",
    "Europe/Kiev",
    "US/Pacific",
    "Asia/Tokyo",
    "America/Argentina/Buenos_Aires",
    "UTC",
  ])("%s is a zone", (name) => {
    assert.isDefined(namedTimeZone(name));
  });

  // UTC offsets, `GMT+9` and the wrong case aren't. An alias in the wrong case (`europe/kyiv`)
  // still passes here, though not on the Mac (851-4185).
  it.each([
    "+09:00",
    "GMT+9",
    "GMT-05:00",
    "GMT+0",
    "asia/tokyo",
    "ASIA/TOKYO",
    "Asia/tokyo",
    "",
    "Japan Standard Time",
    "Mars/Olympus_Mons",
  ])("%j isn't a zone", (name) => {
    assert.isUndefined(namedTimeZone(name));
  });
});

describe("nights in their recorded zones", () => {
  // A night slept in Tokyo, seen from London, is Tokyo's: the night of the 12th, at 23:00 on its
  // clock. On London's clock it would be a day's sleep on the 11th from 15:00, and the 12th's night
  // from 18:45 the evening before.
  it("a night in Tokyo is Tokyo's", () => {
    const london = calendar("Europe/London");
    const days = { start: day(9, london), end: day(16, london) };
    const nights = cardNights(tokyoNight, days, london);
    assert.deepStrictEqual(
      nights.map((night) => night.day),
      [day(12, london)],
    );
    const night = nights[0]!;
    assert.strictEqual(night.timeZone, tokyo);
    assert.strictEqual(night.records.length, 3);
    assert.strictEqual(fallingAsleep(night), utc(11, 14));
    assert.strictEqual(waking(night), utc(11, 21, 30));
    assert.strictEqual(night.inBed, utc(11, 21, 40) - utc(11, 13, 45));
    assert.strictEqual(nightBedtime(night, london), -1);
    // Its clock is Tokyo's, from midnight starting the 12th there.
    const clock = nightClock(night.day, night.timeZone, london);
    assert.strictEqual(clock.calendar.timeZone, tokyo);
    assert.strictEqual(clock.day, day(12, calendar("Asia/Tokyo")));

    // Without zones, as before: split at London's 18:00.
    const before = cardNights(withoutZones(tokyoNight), days, london);
    assert.deepStrictEqual(
      before.map((night) => night.day),
      [day(11, london), day(12, london)],
    );
    assert.deepStrictEqual(
      before.map((night) => nightBedtime(night, london)),
      [undefined, -5.25],
    );
  });

  // A night across a change of zone, flying from New York to London, seen from Auckland: the zone
  // of its last-ending record, London's, from 02:00 BST, the night of the 16th.
  it("a night across a change of zone is the zone's it ended in", () => {
    const auckland = calendar("Pacific/Auckland");
    const records = [
      // 21:00 EDT on the 15th, asleep from 21:00 to 01:00 EDT, then on London's clock.
      record(utc(16, 1), utc(16, 5), core, newYork),
      record(utc(16, 5), utc(16, 6), deep, londonZone),
      record(utc(16, 6), utc(16, 8), core, londonZone),
    ];
    const nights = cardNights(
      records,
      { start: day(16, auckland), end: day(23, auckland) },
      auckland,
    );
    assert.deepStrictEqual(
      nights.map((night) => night.day),
      [day(16, auckland)],
    );
    const night = nights[0]!;
    assert.strictEqual(night.timeZone, londonZone);
    assert.deepStrictEqual(night.records, records);
    assert.strictEqual(nightBedtime(night, auckland), 2);
  });

  // Nights recorded in the calendar's zone are exactly the nights without zones.
  it("one zone is no zone", () => {
    const london = calendar("Europe/London");
    const records = Array.from({ length: 28 }, (_, index) => index + 1).flatMap((date) => [
      record(utc(date, 21), utc(date + 1, 6), core, londonZone),
      record(utc(date + 1, 6), utc(date + 1, 6, 10), awake, londonZone),
      // A nap the next afternoon: another session of the same day.
      record(utc(date + 1, 13), utc(date + 1, 14), core, londonZone),
    ]);
    const days = { start: day(2, london), end: day(29, london) };
    const zoned = cardNights(records, days, london);
    const plain = cardNights(withoutZones(records), days, london);
    assert.strictEqual(zoned.length, 27);
    const sameAs = <A>(read: (night: (typeof zoned)[number]) => A) =>
      assert.deepStrictEqual(zoned.map(read), plain.map(read));
    sameAs((night) => night.day);
    sameAs(fallingAsleep);
    sameAs(waking);
    sameAs((night) => night.inBed);
    sameAs((night) => nightBedtime(night, london));
    assert.isTrue(zoned.every((night) => night.timeZone === londonZone));
    assert.isTrue(plain.every((night) => night.timeZone === undefined));
  });

  // Runs split where a source's sleep stops for 3 hours, in absolute time, each taking the zone of
  // its last-ending record that has one: a record without one doesn't count, and a run without any
  // is the calendar's.
  it("runs and their zones", () => {
    const records = [
      // A run: Tokyo, then a record without a zone ending last.
      record(utc(11, 14), utc(11, 17), core, tokyo),
      record(utc(11, 17), utc(11, 21), core, undefined),
      // 3 hours later: another run, without zones.
      record(utc(12, 0), utc(12, 1), core, undefined),
      // Another source at the same time, in New York: its own run.
      record(utc(11, 15), utc(11, 16), asleep, newYork, "phone"),
    ];
    assert.deepStrictEqual(sleepRunZones(records), [tokyo, tokyo, undefined, newYork]);
  });

  // Records ending at once in two zones: the name that sorts first, whatever their order.
  it("ties go to the name that sorts first", () => {
    const records = [
      record(utc(11, 14), utc(11, 21), core, tokyo),
      record(utc(11, 15), utc(11, 21), rem, londonZone),
    ];
    assert.deepStrictEqual(sleepRunZones(records), [tokyo, tokyo]);
    assert.deepStrictEqual(sleepRunZones([...records].reverse()), [tokyo, tokyo]);
  });

  // A night in a zone 21 hours ahead of the calendar's starts long before the calendar's night
  // could: the fetch reaches it (`nightRecordRange`), and it's the calendar's day of its date.
  it("the fetch reaches far zones", () => {
    const losAngeles = calendar("America/Los_Angeles");
    // 23:00 on the 11th to 06:00 on the 12th in Kiritimati (UTC+14): 02:00 to 09:00 PDT on the
    // 11th.
    const records = [record(utc(11, 9), utc(11, 16), core, "Pacific/Kiritimati")];
    const days = { start: day(12, losAngeles), end: day(13, losAngeles) };
    const range = nightRecordRange(days);
    assert.isTrue(utc(11, 9) >= range.start && utc(11, 9) < range.end);
    assert.isBelow(utc(11, 9), days.start - 6 * 3_600_000);
    const nights = cardNights(records, days, losAngeles);
    assert.deepStrictEqual(
      nights.map((night) => night.day),
      [day(12, losAngeles)],
    );
    assert.strictEqual(nightBedtime(nights[0]!, losAngeles), -1);
    // Without its zone, it's the 11th's day's sleep, outside the days.
    assert.deepStrictEqual(cardNights(withoutZones(records), days, losAngeles), []);
  });
});

describe("the store's sleep records", () => {
  // A record's zone is read only from JSON metadata whose `HKTimeZone` is a zone's name: other
  // metadata loses only the zone, and the record stays (the Mac's `onlyAZonesNameIsAZone`, with
  // a canonical name in the wrong case for its `europe/kyiv`, 851-4185).
  it("have a zone only when their metadata names one", () => {
    const sql = makeTestStoreSql();
    migrate(sql);
    const metadata = [
      '{"HKTimeZone":"Europe/Kyiv"}',
      '{"HKTimeZone":"Europe/Kiev"}',
      null,
      "not JSON",
      '{"HKTimeZone":9}',
      '{"HKTimeZone":"+09:00"}',
      '{"HKTimeZone":"europe/london"}',
      '{"HKTimeZone":null}',
      "{}",
      '["Europe/Kyiv"]',
      '{"HKTimeZone":{"name":"Europe/Kyiv"}}',
    ];
    metadata.forEach((value, index) =>
      sql.exec(
        `INSERT INTO health_sample (id, type, start_date, end_date, category_value, source_name,
          source_bundle_id, metadata)
        VALUES (?, 'HKCategoryTypeIdentifierSleepAnalysis', ?, ?, 3, 'Test', ?, ?)`,
        `00000000-0000-4000-9000-${String(index).padStart(12, "0")}`,
        utc(10, index),
        utc(10, index, 30),
        watch,
        value,
      ),
    );
    const records = cardSleepRecords(sql, { start: utc(10, 0), end: utc(11, 0) });
    assert.deepStrictEqual(
      records.map((record) => record.timeZone),
      ["Europe/Kyiv", "Europe/Kiev", ...Array(9).fill(undefined)],
    );
  });
});
