import Foundation
import HealthDatabase
import Testing

@testable import HealthPages

struct ChartFormatTests {
  private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  // 2025-10-15 12:00 UTC, a Wednesday.
  private let now = Date(timeIntervalSince1970: 1_760_529_600)

  @Test
  func sixMonthsAcrossAYearNameBothYears() {
    let interval = ChartRange.sixMonths.interval(offset: -1, now: now, calendar: utc)
    let span = ChartFormat.span(interval, range: .sixMonths, calendar: utc)
    #expect(span.contains("2024") && span.contains("2025"))
    let current = ChartFormat.span(
      ChartRange.sixMonths.interval(offset: 0, now: now, calendar: utc), range: .sixMonths,
      calendar: utc)
    #expect(current.components(separatedBy: "2025").count == 2)
  }
}
