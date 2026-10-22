import Foundation
import HealthDatabase
import Testing

// `sections(_:by:calendar:startDate:)`, which groups All Data's samples, Food's foods and the
// record lists' records (851-3045). Synthetic records only.

@Suite
struct SectionsTests {
  @Test
  func noRecordsMakeNoSections() {
    #expect(group([], by: .day, in: "UTC").isEmpty)
    #expect(group([], by: .month, in: "America/New_York").isEmpty)
  }

  @Test
  func daysEndAtMidnight() {
    let days = group(
      [
        "2026-01-16T00:00:00.000Z", "2026-01-15T23:59:59.999Z", "2026-01-15T12:00:00.000Z",
        "2026-01-15T00:00:00.000Z", "2026-01-14T23:59:59.999Z", "2026-01-12T08:00:00.000Z",
      ], by: .day, in: "UTC")
    #expect(
      days.map(\.start) == [
        "2026-01-16T00:00:00.000Z", "2026-01-15T00:00:00.000Z", "2026-01-14T00:00:00.000Z",
        "2026-01-12T00:00:00.000Z",
      ])
    #expect(days.map(\.records) == [[0], [1, 2, 3], [4], [5]])
  }

  @Test
  func monthsEndAtTheirLastMidnight() {
    let months = group(
      [
        "2026-03-01T00:00:00.000Z", "2026-02-28T23:59:59.999Z", "2026-02-01T00:00:00.000Z",
        "2026-01-31T23:59:59.999Z", "2025-12-25T08:00:00.000Z",
      ], by: .month, in: "UTC")
    #expect(
      months.map(\.start) == [
        "2026-03-01T00:00:00.000Z", "2026-02-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z",
        "2025-12-01T00:00:00.000Z",
      ])
    #expect(months.map(\.records) == [[0], [1, 2], [3], [4]])
  }

  @Test
  func theCalendarsTimeZoneDecidesTheDay() {
    // The same moments, a few minutes either side of midnight in each zone.
    let records = [
      "2026-01-15T18:31:00.000Z", "2026-01-15T18:29:00.000Z", "2026-01-15T11:01:00.000Z",
      "2026-01-15T10:59:00.000Z", "2026-01-15T05:01:00.000Z", "2026-01-15T04:59:00.000Z",
      "2026-01-15T00:01:00.000Z", "2026-01-14T23:59:00.000Z",
    ]
    // UTC, at 00:00.
    #expect(group(records, by: .day, in: "UTC").map(\.records) == [[0, 1, 2, 3, 4, 5, 6], [7]])
    // New York (UTC-5), at 05:00.
    #expect(
      group(records, by: .day, in: "America/New_York").map(\.records) == [
        [0, 1, 2, 3, 4], [5, 6, 7],
      ])
    // Auckland (UTC+13 in its summer), at 11:00.
    #expect(
      group(records, by: .day, in: "Pacific/Auckland").map(\.records) == [
        [0, 1, 2], [3, 4, 5, 6, 7],
      ])
    // Kolkata (UTC+5:30), at 18:30.
    let kolkata = group(records, by: .day, in: "Asia/Kolkata")
    #expect(kolkata.map(\.start) == ["2026-01-15T18:30:00.000Z", "2026-01-14T18:30:00.000Z"])
    #expect(kolkata.map(\.records) == [[0], [1, 2, 3, 4, 5, 6, 7]])
  }

  @Test
  func aDayLosingAnHourWhenClocksGoForward() {
    // New York, March 8, 2026: 02:00 EST becomes 03:00 EDT, so the day is 23 hours long.
    let days = group(
      [
        "2026-03-09T04:00:00.000Z",  // March 9, 00:00 EDT
        "2026-03-09T03:59:59.999Z",  // March 8, 23:59 EDT
        "2026-03-08T07:00:00.000Z",  // 03:00 EDT, the moment after 01:59:59.999 EST
        "2026-03-08T06:59:59.999Z",  // 01:59 EST
        "2026-03-08T05:00:00.000Z",  // 00:00 EST
        "2026-03-08T04:59:59.999Z",  // March 7, 23:59 EST
      ], by: .day, in: "America/New_York")
    #expect(
      days.map(\.start) == [
        "2026-03-09T04:00:00.000Z", "2026-03-08T05:00:00.000Z", "2026-03-07T05:00:00.000Z",
      ])
    #expect(days.map(\.records) == [[0], [1, 2, 3, 4], [5]])
  }

  @Test
  func aDayGainingAnHourWhenClocksGoBack() {
    // New York, November 1, 2026: 02:00 EDT becomes 01:00 EST, so the day is 25 hours long and
    // its 01:30 comes twice.
    let days = group(
      [
        "2026-11-02T05:00:00.000Z",  // November 2, 00:00 EST
        "2026-11-02T04:59:59.999Z",  // November 1, 23:59 EST
        "2026-11-01T06:30:00.000Z",  // 01:30 EST, the second
        "2026-11-01T05:30:00.000Z",  // 01:30 EDT, the first
        "2026-11-01T04:00:00.000Z",  // 00:00 EDT
        "2026-11-01T03:59:59.999Z",  // October 31, 23:59 EDT
      ], by: .day, in: "America/New_York")
    #expect(
      days.map(\.start) == [
        "2026-11-02T05:00:00.000Z", "2026-11-01T04:00:00.000Z", "2026-10-31T04:00:00.000Z",
      ])
    #expect(days.map(\.records) == [[0], [1, 2, 3, 4], [5]])
  }

  @Test
  func aDayStartingAtOneWhenClocksSkipMidnight() {
    // Santiago, September 6, 2026: 00:00 CLT becomes 01:00 CLST, so the day starts at 01:00.
    let days = group(
      [
        "2026-09-06T04:00:00.000Z",  // September 6, 01:00 CLST
        "2026-09-06T03:59:59.999Z",  // September 5, 23:59 CLT
        "2026-09-05T04:00:00.000Z",  // September 5, 00:00 CLT
      ], by: .day, in: "America/Santiago")
    #expect(days.map(\.start) == ["2026-09-06T04:00:00.000Z", "2026-09-05T04:00:00.000Z"])
    #expect(days.map(\.records) == [[0], [1, 2]])
  }

  @Test
  func aMonthWithAClockChangeIsOneMonth() {
    let months = group(
      [
        "2026-04-01T04:00:00.000Z",  // April 1, 00:00 EDT
        "2026-04-01T03:59:59.999Z",  // March 31, 23:59 EDT
        "2026-03-08T07:00:00.000Z",  // March 8, 03:00 EDT
        "2026-03-08T06:59:59.999Z",  // March 8, 01:59 EST
        "2026-03-01T05:00:00.000Z",  // March 1, 00:00 EST
        "2026-03-01T04:59:59.999Z",  // February 28, 23:59 EST
      ], by: .month, in: "America/New_York")
    #expect(
      months.map(\.start) == [
        "2026-04-01T04:00:00.000Z", "2026-03-01T05:00:00.000Z", "2026-02-01T05:00:00.000Z",
      ])
    #expect(months.map(\.records) == [[0], [1, 2, 3, 4], [5]])
  }

  /// It asks the calendar only when a record leaves the section before it, and makes the same
  /// sections as asking it for every record: here, a record every 7 minutes, newest first,
  /// through a week of each clock change.
  @Test(arguments: [
    "UTC", "America/New_York", "Europe/London", "Pacific/Auckland", "Asia/Kolkata",
    "America/Santiago",
  ])
  func sameSectionsAsAskingForEveryRecord(_ timeZone: String) {
    let calendar = calendar(timeZone)
    for (from, to) in [
      ("2026-03-04T00:00:00.000Z", "2026-03-11T00:00:00.000Z"),
      ("2026-03-26T00:00:00.000Z", "2026-04-08T00:00:00.000Z"),
      ("2026-09-02T00:00:00.000Z", "2026-09-09T00:00:00.000Z"),
      ("2026-09-24T00:00:00.000Z", "2026-10-01T00:00:00.000Z"),
      ("2026-10-22T00:00:00.000Z", "2026-11-04T00:00:00.000Z"),
    ] {
      let records = Array(
        stride(from: date(to).unixMilliseconds, to: date(from).unixMilliseconds, by: -7 * 60_000))
      for component in [Calendar.Component.day, .month] {
        let grouped = sections(records, by: component, calendar: calendar) { $0 }
        var expected: [(start: Date, records: [Int])] = []
        for record in records {
          let start = calendar.dateInterval(of: component, for: Date(unixMilliseconds: record))!
            .start
          if expected.last?.start == start {
            expected[expected.count - 1].records.append(record)
          } else {
            expected.append((start, [record]))
          }
        }
        #expect(grouped.map(\.start) == expected.map(\.start), "\(component), \(from)")
        #expect(grouped.map(\.records) == expected.map(\.records), "\(component), \(from)")
      }
    }
  }

  /// Callers sort their records, but out of order a section still starts each time a record's day
  /// changes, as when the calendar is asked for every record. The last record is at the end of the
  /// day before it, which is the next day's start.
  @Test
  func recordsOutOfOrderStartANewSectionWhenTheirDayChanges() {
    let days = group(
      [
        "2026-01-15T08:00:00.000Z", "2026-01-14T08:00:00.000Z", "2026-01-15T09:00:00.000Z",
        "2026-01-15T07:00:00.000Z", "2026-01-16T00:00:00.000Z",
      ], by: .day, in: "UTC")
    #expect(
      days.map(\.start) == [
        "2026-01-15T00:00:00.000Z", "2026-01-14T00:00:00.000Z", "2026-01-15T00:00:00.000Z",
        "2026-01-16T00:00:00.000Z",
      ])
    #expect(days.map(\.records) == [[0], [1], [2, 3], [4]])
  }
}

/// `records` (moments in ISO 8601, with milliseconds) by `component` in `timeZone`: each
/// section's start, in the same form, and its records' indices.
private func group(
  _ records: [String], by component: Calendar.Component, in timeZone: String
) -> [(start: String, records: [Int])] {
  let records = records.enumerated().map { (index: $0, startDate: date($1).unixMilliseconds) }
  return sections(records, by: component, calendar: calendar(timeZone), startDate: \.startDate)
    .map { (format.format($0.start), $0.records.map(\.index)) }
}

private let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

private func date(_ string: String) -> Date {
  try! format.parse(string)
}

private func calendar(_ timeZone: String) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: timeZone)!
  return calendar
}
