import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

struct SleepChartsTests {
  /// Los Angeles, where daylight saving time started on March 10, 2024 and ended on November 3.
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: 2024, month: month, day: day, hour: hour, minute: minute))!
  }

  @Test
  func nightsCrossingMidnightAreAtTheirClockTimes() {
    let day = date(8, 13, 0)
    let start = date(8, 12, 23)
    #expect(HealthDatabase.clockHours(start, from: day, start: start, calendar: calendar) == -1)
    #expect(
      HealthDatabase.clockHours(date(8, 13, 0, 40), from: day, start: start, calendar: calendar)
        == 40.0 / 60
    )
    #expect(
      HealthDatabase.clockHours(date(8, 13, 7, 30), from: day, start: start, calendar: calendar)
        == 7.5)
  }

  @Test
  func daylightSavingChangesDontMoveTheNights() {
    // In spring, 11 PM to 7 AM is 7 hours: from 11 PM, it ends at 6 on the chart.
    let spring = date(3, 10, 0)
    let springStart = date(3, 9, 23)
    #expect(
      HealthDatabase.clockHours(springStart, from: spring, start: springStart, calendar: calendar)
        == -1)
    #expect(
      HealthDatabase.clockHours(
        date(3, 10, 7), from: spring, start: springStart, calendar: calendar) == 6)
    // In the fall, 9 hours, to 8, and the repeated hour's times keep going down the column.
    let fall = date(11, 3, 0)
    let fallStart = date(11, 2, 23)
    let firstOne = date(11, 3, 1, 30)
    let secondOne = firstOne.addingTimeInterval(3600)
    #expect(
      HealthDatabase.clockHours(date(11, 3, 7), from: fall, start: fallStart, calendar: calendar)
        == 8)
    #expect(
      HealthDatabase.clockHours(secondOne, from: fall, start: fallStart, calendar: calendar)
        == HealthDatabase.clockHours(firstOne, from: fall, start: fallStart, calendar: calendar) + 1
    )
    // A night that starts after the change is at its clock times, as are the nights after.
    let late = date(3, 10, 3, 30)
    #expect(HealthDatabase.clockHours(late, from: spring, start: late, calendar: calendar) == 3.5)
    let next = date(3, 11, 0)
    let nextStart = date(3, 10, 23)
    #expect(
      HealthDatabase.clockHours(nextStart, from: next, start: nextStart, calendar: calendar) == -1)
    #expect(
      HealthDatabase.clockHours(date(3, 11, 7), from: next, start: nextStart, calendar: calendar)
        == 7)
  }

  /// D's hours are marked every 2 hours from the hour the night starts in, on the clock, so a
  /// daylight saving change neither repeats nor misplaces a mark (851-4178).
  @Test
  func hourMarksFollowTheClock() {
    let hours = { (marks: [Date]) in marks.map { calendar.component(.hour, from: $0) } }
    #expect(
      hours(SleepClock.hourMarks(from: date(8, 12, 23, 20), to: date(8, 13, 7), calendar: calendar))
        == [1, 3, 5, 7])
    // The fall's repeated 1 AM is marked once.
    #expect(
      hours(SleepClock.hourMarks(from: date(11, 2, 23), to: date(11, 3, 7), calendar: calendar))
        == [23, 1, 3, 5, 7])
    // Spring's skipped 2 AM is passed over.
    #expect(
      hours(SleepClock.hourMarks(from: date(3, 10, 0), to: date(3, 10, 7), calendar: calendar))
        == [0, 4, 6])
    // On another zone's clock: a night in Kolkata, marked on its half hours in Los Angeles.
    var kolkata = calendar
    kolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    let marks = SleepClock.hourMarks(
      from: date(8, 12, 10, 30), to: date(8, 12, 18), calendar: kolkata)
    #expect(marks.map { kolkata.component(.hour, from: $0) } == [23, 1, 3, 5])
    #expect(calendar.component(.minute, from: marks[0]) == 30)
  }

  @Test
  func slotsAreThePagesDays() {
    let slot = SleepClock.slot(date(8, 13, 0), ratio: 0.5, unit: .day, calendar: calendar)
    #expect(slot.start == date(8, 13, 6))
    #expect(slot.end == date(8, 13, 18))
  }

  @Test
  func theAxisRunsFromWholeMarksAroundTheNights() {
    let axis = SleepClock.axis([-1.25, 7.4, 0.5])
    #expect(axis.domain == -2...8)
    #expect(axis.marks == [-2, 0, 2, 4, 6, 8])
    // Whichever space the format style puts before AM and PM.
    let label = { SleepClock.label($0, calendar: calendar).replacing("\u{202F}", with: " ") }
    #expect(label(-2) == "10 PM")
    #expect(label(0) == "12 AM")
    #expect(label(8) == "8 AM")
    // A day's naps and a night: every 4 hours.
    #expect(SleepClock.axis([-3, 15]).marks == [-4, 0, 4, 8, 12, 16])
  }

  @Test
  func rangesEndWithTodaysNight() {
    let now = date(8, 13, 15)
    func days(_ range: SleepRange, _ offset: Int) -> [Date] {
      [
        range.firstDay(offset: offset, now: now, calendar: calendar),
        range.lastDay(offset: offset, now: now, calendar: calendar),
      ]
    }
    #expect(days(.day, -1) == [date(8, 12, 0), date(8, 12, 0)])
    #expect(days(.week, 0) == [date(8, 7, 0), date(8, 13, 0)])
    #expect(days(.week, -1) == [date(7, 31, 0), date(8, 6, 0)])
    // Months follow each other without a night in two.
    #expect(days(.month, 0) == [date(7, 14, 0), date(8, 13, 0)])
    #expect(days(.month, -1) == [date(6, 14, 0), date(7, 13, 0)])
    // 26 weeks, Sunday to Saturday, ending with this one.
    #expect(days(.sixMonths, 0) == [date(2, 18, 0), date(8, 17, 0)])
    let august2023 = calendar.date(from: DateComponents(year: 2023, month: 8, day: 20))!
    #expect(days(.sixMonths, -1) == [august2023, date(2, 17, 0)])
  }

  /// The period a night falls in, as the page opens on the latest night and keeps the time shown
  /// when the range changes (851-3188): every period's first and last nights map back to it,
  /// across both daylight saving changes.
  @Test
  func eachNightIsInThePeriodItsOffsetNames() {
    let now = date(8, 13, 15)
    for range in SleepRange.allCases {
      for offset in -60...0 {
        let first = range.firstDay(offset: offset, now: now, calendar: calendar)
        let last = range.lastDay(offset: offset, now: now, calendar: calendar)
        for night in [first, last, last.addingTimeInterval(12 * 3600)] {
          #expect(
            range.offset(containing: night, now: now, calendar: calendar) == offset,
            "\(range) \(offset) \(night)")
        }
      }
    }
  }

  @Test
  func sixMonthsBarsAverageEachWeeksTimeAsleep() {
    func night(_ day: Int, asleep: (Date, Date), awakeAfter: Bool = false) -> SleepNight {
      var segments = [SleepSegment(stage: .core, start: asleep.0, end: asleep.1)]
      // Awake after waking isn't time asleep.
      if awakeAfter {
        segments.append(
          SleepSegment(stage: .awake, start: asleep.1, end: asleep.1.addingTimeInterval(3600)))
      }
      return SleepNight(day: date(8, day, 0), segments: segments, inBed: 0)
    }
    let weeks = SleepWeek.weeks(
      [
        // Sunday's and Monday's, one week.
        night(11, asleep: (date(8, 10, 23), date(8, 11, 7)), awakeAfter: true),
        night(12, asleep: (date(8, 12, 0, 30), date(8, 12, 6))),
        // Saturday's, the week before.
        night(10, asleep: (date(8, 9, 22), date(8, 10, 6))),
      ], calendar: calendar)
    #expect(
      weeks == [
        SleepWeek(start: date(8, 4, 0), bedtime: -2, wake: 6),
        SleepWeek(start: date(8, 11, 0), bedtime: -0.25, wake: 6.5),
      ])
  }

  /// Each night is on its own clock (851-4178), as Health draws it: a night slept in Tokyo from
  /// 11 PM to 6:30 AM there is at those times, though it's 7 AM to 2:30 PM in Los Angeles, and a
  /// night that changed zone, New York to London, is on London's clock, where it ended.
  @Test
  func nightsAreOnTheirOwnClocks() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let london = TimeZone(identifier: "Europe/London")!
    // Asleep at 11 PM in Tokyo on August 11, 7 AM in Los Angeles.
    let tokyoNight = SleepNight(
      day: date(8, 12, 0),
      segments: [SleepSegment(stage: .core, start: date(8, 11, 7), end: date(8, 11, 14, 30))],
      inBed: 0, timeZone: tokyo)
    #expect(tokyoNight.clockHours(date(8, 11, 7), calendar: calendar) == -1)
    #expect(tokyoNight.clockHours(date(8, 11, 14, 30), calendar: calendar) == 6.5)
    // Asleep at 9:45 PM in New York, 2:45 AM in London, 6:45 PM in Los Angeles.
    let flight = SleepNight(
      day: date(8, 11, 0),
      segments: [SleepSegment(stage: .core, start: date(8, 10, 18, 45), end: date(8, 10, 23, 15))],
      inBed: 0, timeZone: london)
    #expect(flight.clockHours(date(8, 10, 18, 45), calendar: calendar) == 2.75)
    #expect(flight.clockHours(date(8, 10, 23, 15), calendar: calendar) == 7.25)
    // Without a zone, the page's clock, as before.
    let home = SleepNight(
      day: date(8, 13, 0),
      segments: [SleepSegment(stage: .core, start: date(8, 12, 23), end: date(8, 13, 7))],
      inBed: 0)
    #expect(home.clockHours(date(8, 12, 23), calendar: calendar) == -1)
    // 6M averages them on their own clocks: all three are in the week of Sunday, August 11.
    #expect(
      SleepWeek.weeks([tokyoNight, flight, home], calendar: calendar) == [
        SleepWeek(start: date(8, 11, 0), bedtime: (-1 + 2.75 - 1) / 3, wake: (6.5 + 7.25 + 7) / 3)
      ])
  }
}
