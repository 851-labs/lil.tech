import Foundation
import HealthDatabase
import SwiftUI
import Testing

@testable import HealthPages

/// How a month's calendar moves between days and reads them to VoiceOver (851-3015).
struct MonthCalendarTests {
  private let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }()
  private let locale = Locale(identifier: "en_US")

  /// `day` March 2026, at midnight in London.
  private func march(_ day: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 3, day: day))!
  }

  private var month: DateInterval { DateInterval(start: march(1), end: march(32)) }

  private func move(_ direction: MoveCommandDirection, from day: Int, rightToLeft: Bool = false)
    -> Date?
  {
    MonthCalendar.day(
      moving: direction, from: march(day), in: month,
      layoutDirection: rightToLeft ? .rightToLeft : .leftToRight, calendar: calendar)
  }

  @Test
  func arrowsMoveADayOrAWeek() {
    #expect(move(.left, from: 10) == march(9))
    #expect(move(.right, from: 10) == march(11))
    #expect(move(.up, from: 10) == march(3))
    #expect(move(.down, from: 10) == march(17))
  }

  @Test
  func leftAndRightAreMirroredRightToLeft() {
    #expect(move(.left, from: 10, rightToLeft: true) == march(11))
    #expect(move(.right, from: 10, rightToLeft: true) == march(9))
    #expect(move(.down, from: 10, rightToLeft: true) == march(17))
  }

  @Test
  func arrowsStayInTheMonth() {
    #expect(move(.left, from: 1) == nil)
    #expect(move(.up, from: 7) == nil)
    #expect(move(.right, from: 31) == nil)
    #expect(move(.down, from: 25) == nil)
    // Across the clocks going forward (March 29 in London), still a day.
    #expect(move(.right, from: 29) == march(30))
  }

  @Test
  func aDayReadsItsDateThenWhatItHas() {
    #expect(
      MonthCalendar.label(march(4), isToday: false, details: [], calendar: calendar, locale: locale)
        == "Wednesday, March 4, 2026")
    #expect(
      MonthCalendar.label(
        march(4), isToday: true, details: ["Light Flow", "Cramps"], calendar: calendar,
        locale: locale) == "Wednesday, March 4, 2026, Today, Light Flow, Cramps")
  }

  @Test
  func aCycleDayReadsWhatsLoggedAsItsSectionLists() {
    #expect(CycleDayCell.logged(nil) == [])
    #expect(CycleDayCell.logged(CycleDay()) == [])
    let day = CycleDay(
      flow: .medium, spotting: true, ovulationPositive: true, sexualActivity: true,
      symptoms: ["Cramps", "Headache"],
      log: [
        CycleLogEntry(name: "Ovulation Test Result", value: "Positive"),
        CycleLogEntry(name: "Pregnancy Test Result", value: nil),
      ])
    #expect(
      CycleDayCell.logged(day) == [
        "Medium Flow", "Spotting", "Sexual Activity", "Ovulation Test Result: Positive",
        "Pregnancy Test Result", "Cramps", "Headache",
      ])
  }

  @Test
  func anActivityDayReadsItsRings() {
    #expect(ActivityDayCell.rings(nil) == "No Activity Rings")
    let day = ActivityDay(
      id: "2026-03-04", move: ActivityRing(value: 420, goal: 500),
      exercise: ActivityRing(value: 30, goal: 30), stand: nil, isPaused: true)
    #expect(ActivityDayCell.rings(day) == "Move 84%, Exercise 100%, Paused")
  }
}
