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

  private func period<R: PeriodRange>(_ box: Box<R>) -> PagePeriod {
    PagePeriod(
      range: Binding(get: { box.range }, set: { box.range = $0 }),
      offset: Binding(get: { box.offset }, set: { box.offset = $0 }))
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
  func choosingARangeStartsAtItsCurrentPeriod() {
    let box = Box(ChartRange.week)
    period(box).select(2)
    #expect(box.range == .month)
    #expect(box.offset == 0)
  }

  @Test
  func theToolbarsPickerChoosesARange() {
    let box = Box(ChartRange.week)
    period(box).rangeSelection.wrappedValue = 4
    #expect(box.range == .year)
    #expect(box.offset == 0)
    #expect(period(box).rangeSelection.wrappedValue == 4)
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
