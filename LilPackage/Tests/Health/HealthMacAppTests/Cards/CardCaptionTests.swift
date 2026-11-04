import Foundation
import HealthCards
import HealthUI
import Testing

@testable import HealthMacApp

/// The full-page card's header captions (851-3107, 851-3244). Loading, No Data and hovering
/// aren't all in the catalogs, so the captions are checked here.
struct CardCaptionTests {
  private let morningWeight = try! CardSpec(
    inputJSON: Data(
      #"{"version": 1, "display": {"name": "Morning Weight"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#
        .utf8))
  private let latestHRV = try! CardSpec(
    inputJSON: Data(
      #"{"version": 1, "display": {"name": "HRV"}, "series": [{"type": "HeartRateVariabilitySDNN", "aggregation": "latest"}]}"#
        .utf8))

  private func caption(
    _ spec: CardSpec, _ range: CardRange, _ summary: CardSummary? = nil, point: LeadPoint? = nil
  ) -> String {
    CardChart.caption(for: spec, range: range, summary: summary, point: point)
  }

  /// Before a period loads, and with No Data, the caption is the one its data will have: a
  /// `first` or `latest` series' points' AVERAGE over many buckets, so it doesn't change as the
  /// period arrives.
  @Test
  func aPickedSeriesCaptionsItsPeriodAsItWillLoad() {
    for range in [CardRange.week, .month, .sixMonths, .year] {
      #expect(caption(morningWeight, range) == "AVERAGE")
      #expect(caption(latestHRV, range) == "AVERAGE")
    }
    // At D, the day's reading.
    #expect(caption(latestHRV, .day) == "LATEST")
    #expect(caption(morningWeight, .month, CardSummary(kind: .average, value: 70.9)) == "AVERAGE")
  }

  /// A hovered point is its bucket's reading.
  @Test
  func aPickedSeriesPointIsItsReading() {
    let point = LeadPoint(start: .now, value: 70.5, minimum: 70.5, maximum: 70.5)
    #expect(caption(morningWeight, .month, point: point) == "FIRST")
    #expect(caption(latestHRV, .week, point: point) == "LATEST")
  }
}
