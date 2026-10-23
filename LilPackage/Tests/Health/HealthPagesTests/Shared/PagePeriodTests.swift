import HealthDatabase
import SwiftUI
import Testing

@testable import HealthPages

@MainActor
struct PagePeriodTests {
  /// A page's range and offset in plain variables, as its state would hold them.
  private final class Box<R> {
    var range: R
    var offset = -3

    init(_ range: R) {
      self.range = range
    }
  }

  private let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()

  /// `month` `day`, 2025, at `hour` UTC. October 15 is a Wednesday.
  private func date(_ month: Int, _ day: Int, _ hour: Int = 0, year: Int = 2025) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  private var now: Date { date(10, 15, 12) }

  private func period<R: PeriodRange>(_ box: Box<R>) -> PagePeriod {
    PagePeriod(
      range: Binding(get: { box.range }, set: { box.range = $0 }),
      offset: Binding(get: { box.offset }, set: { box.offset = $0 }), now: now,
      calendar: calendar)
  }

  @Test
  func listsThePagesRanges() {
    let metric = period(Box(ChartRange.week))
    #expect(metric.ranges.map(\.label) == ["D", "W", "M", "6M", "Y"])
    #expect(metric.ranges.map(\.name) == ["Day", "Week", "Month", "6 Months", "Year"])
    #expect(metric.selected == 1)
    #expect(metric.name == "Week")

    let sleep = period(Box(SleepRange.day))
    #expect(sleep.ranges.map(\.label) == ["D", "W", "M", "6M"])
    #expect(sleep.name == "Night")
  }

  @Test
  func choosingARangeFromTheCurrentPeriodShowsItsCurrentPeriod() {
    let box = Box(ChartRange.week)
    box.offset = 0
    period(box).select(2)
    #expect(box.range == .month)
    #expect(box.offset == 0)
    // This year's December is still to come: this year, not the next.
    period(box).select(4)
    period(box).select(0)
    #expect(box.range == .day)
    #expect(box.offset == 0)
  }

  /// W → M shows the month with most of the shown week, and M → W the month's last week
  /// mostly in it, so going back and forth comes back to the same period (851-3188).
  @Test
  func choosingARangeKeepsTheTimeShown() {
    // Sep 21 – 27.
    let box = Box(ChartRange.week)
    period(box).select(2)
    #expect(box.range == .month)
    #expect(box.offset == -1)
    // September's last week mostly in it: Sep 21 – 27, not Sep 28 – Oct 4.
    period(box).select(1)
    #expect(box.offset == -3)
    // Aug 31 – Sep 6, mostly September's.
    box.offset = -6
    period(box).select(2)
    #expect(box.offset == -1)
    // 2024, then its last six months, May – Oct, not Nov 2024 – Apr 2025, and back.
    box.range = .year
    box.offset = -1
    period(box).select(3)
    #expect(box.offset == -2)
    #expect(
      ChartRange.sixMonths.interval(offset: -2, now: now, calendar: calendar).start
        == date(5, 1, year: 2024))
    period(box).select(4)
    #expect(box.offset == -1)
    // The last day of Nov 2024 – Apr 2025: April.
    box.range = .sixMonths
    box.offset = -1
    period(box).select(2)
    #expect(box.offset == -6)
    period(box).select(0)
    #expect(box.range == .day)
    #expect(
      ChartRange.day.interval(offset: box.offset, now: now, calendar: calendar).start
        == date(4, 30))
  }

  @Test
  func sleepsRangesKeepTheTimeShownToo() {
    // Today's night, Oct 15, and the ones before it.
    let box = Box(SleepRange.day)
    box.offset = -20
    period(box).select(1)
    // Sep 25's night: the week of nights Sep 25 – Oct 1.
    #expect(box.offset == -2)
    #expect(SleepRange.week.lastDay(offset: -2, now: now, calendar: calendar) == date(10, 1))
    period(box).select(2)
    // Sep 16 – Oct 15's month.
    #expect(box.offset == 0)
  }

  @Test
  func theToolbarsPickerChoosesARange() {
    let box = Box(ChartRange.week)
    box.offset = 0
    period(box).rangeSelection.wrappedValue = 4
    #expect(box.range == .year)
    #expect(box.offset == 0)
    #expect(period(box).rangeSelection.wrappedValue == 4)
  }

  /// A page opens on its latest data's period when the current one has none (851-3188).
  @Test
  func opensOnTheLatestPeriodWithData() {
    let opening = { (range: ChartRange, latest: Date?) in
      range.openingOffset(latest: latest, now: self.now, calendar: self.calendar)
    }
    // Earlier this week, or nothing at all: this week.
    #expect(opening(.week, date(10, 13)) == 0)
    #expect(opening(.week, nil) == 0)
    // Three weeks ago: Sep 21 – 27.
    #expect(opening(.week, date(9, 24, 20)) == -3)
    #expect(opening(.month, date(9, 24, 20)) == -1)
    // Dated ahead: still this week.
    #expect(opening(.week, date(10, 30)) == 0)
    #expect(SleepRange.day.openingOffset(latest: date(9, 25), now: now, calendar: calendar) == -20)
  }

  @Test
  func pressesFasterThanThePageRedrawsEachCount() {
    // One period, as the menu holds it until the page publishes a new one.
    let box = Box(ChartRange.week)
    let stale = period(box)
    stale.previous()
    stale.previous()
    #expect(box.offset == -5)
    stale.next()
    #expect(box.offset == -4)
  }

  @Test
  func choosingTheRangeShownKeepsThePeriod() {
    let box = Box(SleepRange.week)
    period(box).select(1)
    #expect(box.offset == -3)
    period(box).select(7)
    #expect(box.range == .week)
  }

  @Test
  func movesBetweenPeriodsUpToTheCurrentOne() {
    let box = Box(ChartRange.day)
    period(box).previous()
    #expect(box.offset == -4)
    #expect(period(box).canGoForward)
    period(box).next()
    #expect(box.offset == -3)
    period(box).today()
    #expect(box.offset == 0)
    #expect(period(box).isCurrent)
    #expect(!period(box).canGoForward)
    period(box).next()
    #expect(box.offset == 0)
  }
}
