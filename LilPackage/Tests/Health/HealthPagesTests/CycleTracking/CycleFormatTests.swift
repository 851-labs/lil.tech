import Foundation
import Testing

@testable import HealthPages

struct CycleFormatTests {
  private let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }()

  /// `day` March 2026, at `hour`, `minute` and `second` in London.
  private func march(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(
        year: 2026, month: 3, day: day, hour: hour, minute: minute, second: second))!
  }

  /// With plain spaces for the thin ones around the dash.
  private func days(_ start: Date, _ end: Date) -> String {
    CycleFormat.days(from: start, to: end, calendar: calendar, locale: Locale(identifier: "en_GB"))
      .replacing(/\s/, with: " ")
  }

  @Test
  func anEndAtMidnightIsTheDayBefore() {
    #expect(days(march(1), march(4)) == "1 – 3 Mar 2026")
  }

  @Test
  func anEndAtTheLastSecondIsThatDay() {
    #expect(days(march(1), march(3, 23, 59, 59)) == "1 – 3 Mar 2026")
  }

  @Test
  func aRangeWithinADayIsThatDay() {
    #expect(days(march(2, 9), march(2, 17)) == "2 Mar 2026")
    // Ending at the next midnight.
    #expect(days(march(2, 9), march(3)) == "2 Mar 2026")
    // A day from midnight to midnight.
    #expect(days(march(2), march(3)) == "2 Mar 2026")
  }

  @Test
  func aZeroLengthRangeAtMidnightIsThatDay() {
    #expect(days(march(2), march(2)) == "2 Mar 2026")
  }

  @Test
  func aRangeEndingBeforeItStartsIsItsFirstDay() {
    #expect(days(march(2, 9), march(1, 12)) == "2 Mar 2026")
  }

  /// Midnight in the calendar's time zone, not UTC's: London is an hour ahead in summer.
  @Test
  func midnightIsTheCalendarsOwn() {
    let june = { (day: Int, hour: Int) in
      self.calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour))!
    }
    #expect(days(june(1, 0), june(4, 0)) == "1 – 3 Jun 2026")
    // Midnight UTC is 1am in London: the 4th counts.
    #expect(days(june(1, 0), june(4, 1)) == "1 – 4 Jun 2026")
  }
}
