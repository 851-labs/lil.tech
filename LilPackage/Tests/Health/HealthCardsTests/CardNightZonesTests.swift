import Foundation
import Testing

@testable import HealthCards

// Nights in the zone their records were recorded in (851-4174, docs/decisions/cards.md ›
// Recorded time zones), on a synthetic trip in June 2025, as the conformance cases' dataset has
// it. The server's `CardNights.ts` has these cases too.

private let watch = "com.apple.health.watch"
private let (inBed, asleep, awake, core, deep, rem) = (0, 1, 2, 3, 4, 5)
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let newYork = TimeZone(identifier: "America/New_York")!
private let londonZone = TimeZone(identifier: "Europe/London")!

private func calendar(_ zone: String) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: zone)!
  calendar.firstWeekday = 2
  return calendar
}

/// A UTC time in June 2025.
private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Int {
  ms(
    calendar("UTC").date(
      from: DateComponents(year: 2025, month: 6, day: day, hour: hour, minute: minute))!)
}

/// The start of a day of June 2025 in `calendar`.
private func day(_ day: Int, _ calendar: Calendar) -> Date {
  calendar.date(from: DateComponents(year: 2025, month: 6, day: day))!
}

private func record(
  _ start: Int, _ end: Int, _ value: Int, _ zone: TimeZone?, source: String = watch
) -> CardSleepRecord {
  CardSleepRecord(start: start, end: end, value: value, source: source, timeZone: zone)
}

/// The Watch's night in Tokyo: 23:00 JST on 11 June to 06:30 JST on the 12th (14:00Z to
/// 21:30Z), 15:00 to 22:30 on London's clock.
private func tokyoNight(_ zone: TimeZone? = tokyo) -> [CardSleepRecord] {
  [
    record(utc(11, 13, 45), utc(11, 21, 40), inBed, zone),
    record(utc(11, 14), utc(11, 17, 30), core, zone),
    record(utc(11, 17, 30), utc(11, 17, 45), awake, zone),
    record(utc(11, 17, 45), utc(11, 21, 30), rem, zone),
  ]
}

struct CardNightZonesTests {
  // MARK: - Zone names

  /// IANA names, and the old aliases Apple may write (`TimeZone.current.identifier`), are zones.
  @Test(arguments: [
    "Asia/Kolkata", "Asia/Calcutta", "Europe/Kyiv", "Europe/Kiev", "US/Pacific", "Asia/Tokyo",
    "America/Argentina/Buenos_Aires", "UTC",
  ])
  func zoneNames(_ name: String) {
    #expect(CardTimeZone.named(name) != nil)
  }

  /// UTC offsets, `GMT+9` (which `TimeZone(identifier:)` takes) and the wrong case aren't.
  @Test(arguments: [
    "+09:00", "GMT+9", "GMT-05:00", "asia/tokyo", "ASIA/TOKYO", "Asia/tokyo", "",
    "Japan Standard Time", "Mars/Olympus_Mons",
  ])
  func notZoneNames(_ name: String) {
    #expect(CardTimeZone.named(name) == nil)
  }

  // MARK: - Nights

  /// A night slept in Tokyo, seen from London, is Tokyo's: the night of the 12th, at 23:00 on
  /// its clock. On London's clock it would be a day's sleep on the 11th from 15:00, and the 12th's
  /// night from 18:45 the evening before.
  @Test
  func aNightInTokyo() throws {
    let london = calendar("Europe/London")
    let days = day(9, london)..<day(16, london)
    let nights = CardNights.nights(tokyoNight(), days: days, calendar: london)
    #expect(nights.map(\.day) == [day(12, london)])
    let night = try #require(nights.first)
    #expect(night.timeZone == tokyo)
    #expect(night.records.count == 3)
    #expect(night.fallingAsleep == utc(11, 14))
    #expect(night.waking == utc(11, 21, 30))
    #expect(night.inBed == utc(11, 21, 40) - utc(11, 13, 45))
    #expect(night.nightBedtime(calendar: london) == -1)
    // Its clock is Tokyo's, from midnight starting the 12th there.
    let clock = CardNights.clock(day: night.day, timeZone: night.timeZone, calendar: london)
    #expect(clock.calendar.timeZone == tokyo)
    #expect(clock.day == day(12, calendar("Asia/Tokyo")))

    // Without zones, as before: split at London's 18:00.
    let before = CardNights.nights(tokyoNight(nil), days: days, calendar: london)
    #expect(before.map(\.day) == [day(11, london), day(12, london)])
    #expect(before.map { $0.nightBedtime(calendar: london) } == [nil, -5.25])
  }

  /// A night across a change of zone, flying from New York to London, seen from Auckland: the
  /// zone of its last-ending record, London's, from 02:00 BST, the night of the 16th.
  @Test
  func aNightAcrossAChangeOfZone() throws {
    let auckland = calendar("Pacific/Auckland")
    let records = [
      // 21:00 EDT on the 15th, asleep from 21:00 to 01:00 EDT, then on London's clock.
      record(utc(16, 1), utc(16, 5), core, newYork),
      record(utc(16, 5), utc(16, 6), deep, londonZone),
      record(utc(16, 6), utc(16, 8), core, londonZone),
    ]
    let nights = CardNights.nights(
      records, days: day(16, auckland)..<day(23, auckland), calendar: auckland)
    #expect(nights.map(\.day) == [day(16, auckland)])
    let night = try #require(nights.first)
    #expect(night.timeZone == londonZone)
    #expect(night.records == records)
    #expect(night.nightBedtime(calendar: auckland) == 2)
  }

  /// Nights recorded in the calendar's zone are exactly the nights without zones.
  @Test
  func oneZoneIsNoZone() {
    let london = calendar("Europe/London")
    let records = (1...28).flatMap { day in
      [
        record(utc(day, 21), utc(day + 1, 6), core, londonZone),
        record(utc(day + 1, 6), utc(day + 1, 6, 10), awake, londonZone),
        // A nap the next afternoon: another session of the same day.
        record(utc(day + 1, 13), utc(day + 1, 14), core, londonZone),
      ]
    }
    let days = day(2, london)..<day(29, london)
    let zoned = CardNights.nights(records, days: days, calendar: london)
    let plain = CardNights.nights(
      records.map {
        CardSleepRecord(start: $0.start, end: $0.end, value: $0.value, source: $0.source)
      },
      days: days, calendar: london)
    #expect(zoned.count == 27)
    #expect(zoned.map(\.day) == plain.map(\.day))
    #expect(zoned.map(\.fallingAsleep) == plain.map(\.fallingAsleep))
    #expect(zoned.map(\.waking) == plain.map(\.waking))
    #expect(zoned.map(\.inBed) == plain.map(\.inBed))
    #expect(
      zoned.map { $0.nightBedtime(calendar: london) }
        == plain.map { $0.nightBedtime(calendar: london) })
    #expect(zoned.allSatisfy { $0.timeZone == londonZone })
    #expect(plain.allSatisfy { $0.timeZone == nil })
  }

  /// Runs split where a source's sleep stops for 3 hours, in absolute time, each taking the zone
  /// of its last-ending record that has one: a record without one doesn't count, and a run
  /// without any is the calendar's.
  @Test
  func runsAndTheirZones() {
    let records = [
      // A run: Tokyo, then a record without a zone ending last.
      record(utc(11, 14), utc(11, 17), core, tokyo),
      record(utc(11, 17), utc(11, 21), core, nil),
      // 3 hours later: another run, without zones.
      record(utc(12, 0), utc(12, 1), core, nil),
      // Another source at the same time, in New York: its own run.
      record(utc(11, 15), utc(11, 16), asleep, newYork, source: "phone"),
    ]
    #expect(CardNights.runZones(records) == [tokyo, tokyo, nil, newYork])
  }

  /// Records ending at once in two zones: the name that sorts first, whatever their order.
  @Test
  func tiesGoToTheNameThatSortsFirst() {
    let records = [
      record(utc(11, 14), utc(11, 21), core, tokyo),
      record(utc(11, 15), utc(11, 21), rem, londonZone),
    ]
    #expect(CardNights.runZones(records) == [tokyo, tokyo])
    #expect(CardNights.runZones(records.reversed()) == [tokyo, tokyo])
  }

  /// A night keeps its zone's name as its records gave it (851-4177), which `TimeZone` may not:
  /// it calls `UTC` `GMT`. Ties compare those names, as the server's do: `Pacific/Auckland` sorts
  /// before `UTC`, though not before `GMT`.
  @Test
  func aNightKeepsItsZonesName() throws {
    let utcZone = try #require(CardTimeZone.named("UTC"))
    #expect(utcZone.identifier == "GMT")
    let records = [
      CardSleepRecord(
        start: utc(11, 23), end: utc(12, 6), value: core, source: watch, timeZone: utcZone,
        timeZoneName: "UTC"),
      record(utc(12, 0), utc(12, 6), rem, TimeZone(identifier: "Pacific/Auckland")),
    ]
    let nights = CardNights.nights(
      records, days: day(12, calendar("UTC"))..<day(13, calendar("UTC")),
      calendar: calendar("UTC"))
    // Both end at 06:00Z.
    #expect(nights.map(\.timeZoneName) == ["Pacific/Auckland"])
    #expect(CardNights.runs(records).map(\.timeZoneName) == ["Pacific/Auckland"])
    #expect(
      CardSleepRecord(start: 0, end: 1, value: core, source: watch, timeZone: tokyo).timeZoneName
        == "Asia/Tokyo")
    #expect(CardSleepRecord(start: 0, end: 1, value: core, source: watch).timeZoneName == nil)
  }

  /// A night in a zone 21 hours ahead of the calendar's starts long before the calendar's night
  /// could: the fetch reaches it (`recordRange`), and it's the calendar's day of its date.
  @Test
  func theFetchReachesFarZones() throws {
    let losAngeles = calendar("America/Los_Angeles")
    let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!  // UTC+14
    // 23:00 on the 11th to 06:00 on the 12th in Kiritimati: 02:00 to 09:00 PDT on the 11th.
    let records = [record(utc(11, 9), utc(11, 16), core, kiritimati)]
    let days = day(12, losAngeles)..<day(13, losAngeles)
    #expect(CardNights.recordRange(days: days).contains(utc(11, 9)))
    #expect(utc(11, 9) < ms(days.lowerBound) - 6 * 3_600_000)
    let nights = CardNights.nights(records, days: days, calendar: losAngeles)
    #expect(nights.map(\.day) == [day(12, losAngeles)])
    #expect(nights.first?.nightBedtime(calendar: losAngeles) == -1)
    // Without its zone, it's the 11th's day's sleep, outside the days.
    #expect(
      CardNights.nights(
        records.map {
          CardSleepRecord(start: $0.start, end: $0.end, value: $0.value, source: $0.source)
        },
        days: days, calendar: losAngeles
      ).isEmpty)
  }
}
