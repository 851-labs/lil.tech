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
    #expect(SleepClock.hours(start, from: day, start: start, calendar: calendar) == -1)
    #expect(
      SleepClock.hours(date(8, 13, 0, 40), from: day, start: start, calendar: calendar) == 40.0 / 60
    )
    #expect(
      SleepClock.hours(date(8, 13, 7, 30), from: day, start: start, calendar: calendar) == 7.5)
  }

  @Test
  func daylightSavingChangesDontMoveTheNights() {
    // In spring, 11 PM to 7 AM is 7 hours: from 11 PM, it ends at 6 on the chart.
    let spring = date(3, 10, 0)
    let springStart = date(3, 9, 23)
    #expect(
      SleepClock.hours(springStart, from: spring, start: springStart, calendar: calendar) == -1)
    #expect(
      SleepClock.hours(date(3, 10, 7), from: spring, start: springStart, calendar: calendar) == 6)
    // In the fall, 9 hours, to 8, and the repeated hour's times keep going down the column.
    let fall = date(11, 3, 0)
    let fallStart = date(11, 2, 23)
    let firstOne = date(11, 3, 1, 30)
    let secondOne = firstOne.addingTimeInterval(3600)
    #expect(SleepClock.hours(date(11, 3, 7), from: fall, start: fallStart, calendar: calendar) == 8)
    #expect(
      SleepClock.hours(secondOne, from: fall, start: fallStart, calendar: calendar)
        == SleepClock.hours(firstOne, from: fall, start: fallStart, calendar: calendar) + 1)
    // A night that starts after the change is at its clock times, as are the nights after.
    let late = date(3, 10, 3, 30)
    #expect(SleepClock.hours(late, from: spring, start: late, calendar: calendar) == 3.5)
    let next = date(3, 11, 0)
    let nextStart = date(3, 10, 23)
    #expect(SleepClock.hours(nextStart, from: next, start: nextStart, calendar: calendar) == -1)
    #expect(SleepClock.hours(date(3, 11, 7), from: next, start: nextStart, calendar: calendar) == 7)
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
}
