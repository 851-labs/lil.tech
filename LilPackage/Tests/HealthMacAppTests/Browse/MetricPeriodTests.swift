import HealthDatabase
import SwiftUI
import Testing

@testable import HealthMacApp

@MainActor
struct MetricPeriodTests {
  /// A period over plain variables, as the page's state would hold it.
  private final class Box {
    var range = ChartRange.week
    var offset = -3
  }

  private func period(_ box: Box) -> MetricPeriod {
    MetricPeriod(
      range: Binding(get: { box.range }, set: { box.range = $0 }),
      offset: Binding(get: { box.offset }, set: { box.offset = $0 }))
  }

  @Test
  func choosingARangeStartsAtItsCurrentPeriod() {
    let box = Box()
    period(box).select(.month)
    #expect(box.range == .month)
    #expect(box.offset == 0)

    // As the toolbar's picker does.
    period(box).offset = -2
    period(box).rangeSelection.wrappedValue = .year
    #expect(box.range == .year)
    #expect(box.offset == 0)
  }

  @Test
  func choosingTheRangeShownKeepsThePeriod() {
    let box = Box()
    period(box).select(.week)
    #expect(box.offset == -3)
  }

  @Test
  func movesBetweenPeriodsUpToTheCurrentOne() {
    let box = Box()
    let period = period(box)
    period.previous()
    #expect(box.offset == -4)
    #expect(period.canGoForward)
    period.today()
    #expect(box.offset == 0)
    #expect(period.isCurrent)
    #expect(!period.canGoForward)
    period.next()
    #expect(box.offset == 0)
  }

  @Test
  func eachRangeNamesItsPeriod() {
    #expect(ChartRange.allCases.map(\.periodName) == ["Day", "Week", "Month", "6 Months", "Year"])
  }
}
