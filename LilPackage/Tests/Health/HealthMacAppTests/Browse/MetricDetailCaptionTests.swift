import Foundation
import HealthCatalog
import HealthDatabase
import Testing

@testable import HealthMacApp

/// Metric Detail's header captions (851-3099, 851-3107). Hovering can't be snapshotted, so its
/// captions are checked here.
@MainActor
struct MetricDetailCaptionTests {
  private let steps = HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!
  private let weight = HealthCatalog.type(id: "HKQuantityTypeIdentifierBodyMass")!
  private let heartRate = HealthCatalog.type(id: HealthDatabase.heartRateType)!
  private let handwashing = HealthCatalog.type(id: HealthDatabase.handwashingType)!
  private let toothbrushing = HealthCatalog.type(id: HealthDatabase.toothbrushingType)!
  private let mindful = HealthCatalog.type(id: HealthDatabase.mindfulSessionType)!
  private let bar = ChartPoint(start: .now, value: 3)

  private func caption(
    _ type: HealthDataType, _ range: ChartRange, _ summary: MetricChart.Summary? = nil,
    point: ChartPoint? = nil
  ) -> String {
    MetricDetailContent.caption(for: type, range: range, summary: summary, point: point)
  }

  /// A cumulative type's captions for each range: the period's, and a hovered bar's.
  private let totals: [(ChartRange, period: String, barCaption: String)] = [
    (.day, "TOTAL", "TOTAL"),
    (.week, "AVERAGE", "TOTAL"),
    (.month, "AVERAGE", "TOTAL"),
    (.sixMonths, "DAILY AVERAGE", "DAILY AVERAGE"),
    (.year, "DAILY AVERAGE", "DAILY AVERAGE"),
  ]

  @Test
  func aTotalsPeriodAndItsBarsShareOneRule() {
    for (range, period, barCaption) in totals {
      // Loading, empty and loaded alike.
      #expect(caption(steps, range) == period)
      #expect(caption(steps, range, .dailyAverage(8_000)) == period)
      #expect(caption(steps, range, point: bar) == barCaption)
      // A category type charted as totals.
      #expect(caption(mindful, range) == period)
      #expect(caption(mindful, range, point: bar) == barCaption)
    }
  }

  @Test
  func sessionsKeepTheirAverageDurationWhateverHasLoaded() {
    for type in [handwashing, toothbrushing] {
      for (range, _, barCaption) in totals {
        // Loading or without sessions, then loaded: one caption, so nothing changes on load.
        #expect(caption(type, range) == "AVERAGE DURATION")
        #expect(caption(type, range, .averageDuration(20)) == "AVERAGE DURATION")
        // A bar is its number of sessions, captioned as any total's.
        #expect(caption(type, range, point: bar) == barCaption)
      }
    }
  }

  @Test
  func otherTypesCaptionTheirAverageOrRange() {
    #expect(caption(weight, .month) == "AVERAGE")
    #expect(caption(weight, .month, .average(72), point: bar) == "AVERAGE")
    #expect(caption(heartRate, .week) == "RANGE")
    #expect(caption(heartRate, .week, .range(minimum: 50, maximum: 120)) == "RANGE")
    #expect(caption(heartRate, .week, .average(60)) == "AVERAGE")
    #expect(
      caption(heartRate, .week, point: ChartPoint(start: .now, value: 70, minimum: 50, maximum: 90))
        == "RANGE")
    #expect(caption(heartRate, .week, point: bar) == "AVERAGE")
  }
}
