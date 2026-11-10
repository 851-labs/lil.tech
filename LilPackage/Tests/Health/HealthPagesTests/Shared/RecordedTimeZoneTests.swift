import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

/// A calendar in Los Angeles, in `en_US`, as the snapshot catalogs' (`previewCalendar`).
private let losAngeles: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  calendar.locale = Locale(identifier: "en_US")
  return calendar
}()

/// Friday, 6 November 2026, 07:00 in Tokyo (Thursday the 5th, 2 PM in Los Angeles).
private let tokyoMorning = Date(timeIntervalSince1970: 1_793_916_000)
/// Saturday, 4 July 2026, 12:00 UTC: summer in London and New York.
private let july = Date(timeIntervalSince1970: 1_783_166_400)

struct RecordedTimeZoneTests {
  @Test
  func namesTheZoneAsHealthDoesWithItsClockWhenItDiffers() {
    let zone = RecordedTimeZone("Asia/Tokyo", start: tokyoMorning, calendar: losAngeles)
    #expect(zone?.name == "Japan Standard Time")
    // A narrow no-break space before AM, as Foundation writes it.
    #expect(zone?.localStart == "11/6/2026, 7:00\u{202F}AM")
  }

  @Test
  func standardOrDaylightAsAtTheStart() {
    #expect(
      RecordedTimeZone("Europe/London", start: july, calendar: losAngeles)?.name
        == "British Summer Time")
    #expect(
      RecordedTimeZone("Europe/London", start: tokyoMorning, calendar: losAngeles)?.name
        == "Greenwich Mean Time")
    #expect(
      RecordedTimeZone("America/New_York", start: july, calendar: losAngeles)?.name
        == "Eastern Daylight Time")
    // Always on daylight saving time in the time zone database, but not "Summer Time" to ICU.
    #expect(
      RecordedTimeZone("Africa/Casablanca", start: july, calendar: losAngeles)?.name
        == "GMT+01:00")
  }

  @Test
  func theViewersOffsetAddsNoClock() {
    let zone = RecordedTimeZone("America/Los_Angeles", start: july, calendar: losAngeles)
    #expect(zone?.name == "Pacific Daylight Time")
    #expect(zone?.localStart == nil)
    // An alias, with the same offset.
    #expect(RecordedTimeZone("US/Pacific", start: july, calendar: losAngeles)?.localStart == nil)
  }

  @Test
  func utcStaysUTC() {
    // Foundation reads `UTC` as `GMT`, "Greenwich Mean Time".
    #expect(
      RecordedTimeZone("UTC", start: july, calendar: losAngeles)?.name
        == "Coordinated Universal Time")
    #expect(
      RecordedTimeZone("GMT", start: july, calendar: losAngeles)?.name == "Greenwich Mean Time")
  }

  @Test
  func onlyNamesTheToolsTake() {
    #expect(RecordedTimeZone(nil, start: july, calendar: losAngeles) == nil)
    #expect(RecordedTimeZone("", start: july, calendar: losAngeles) == nil)
    #expect(RecordedTimeZone("+09:00", start: july, calendar: losAngeles) == nil)
    #expect(RecordedTimeZone("GMT+9", start: july, calendar: losAngeles) == nil)
    #expect(RecordedTimeZone("asia/tokyo", start: july, calendar: losAngeles) == nil)
    #expect(RecordedTimeZone("Mars/Olympus_Mons", start: july, calendar: losAngeles) == nil)
  }

  @Test
  func samplesReadTheirZone() {
    let sample = HealthSample(
      id: "s", type: "HKQuantityTypeIdentifierHeartRate", startDate: 0, endDate: 0, value: 60,
      unit: "count/min", sourceName: "Watch", sourceBundleID: "com.example.watch",
      metadata: #"{"HKTimeZone":"Asia/Tokyo","HKWasUserEntered":false}"#)
    #expect(sample.timeZoneName == "Asia/Tokyo")
    #expect(
      HealthSample(
        id: "s", type: "t", startDate: 0, endDate: 0, sourceName: "Watch",
        sourceBundleID: "com.example.watch", metadata: #"{"HKTimeZone":9}"#
      ).timeZoneName == nil)
    #expect(
      HealthSample(
        id: "s", type: "t", startDate: 0, endDate: 0, sourceName: "Watch",
        sourceBundleID: "com.example.watch", metadata: "not JSON"
      ).timeZoneName == nil)
  }
}
