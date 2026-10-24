import Foundation
import Testing

@testable import HealthCards

/// Legends (docs/decisions/cards.md, UI › The legend): a line for each visible series and formula,
/// only when there's more than one.
struct CardLegendTests {
  func spec(_ text: String) throws -> CardSpec {
    try CardSpec(inputJSON: Data(text.utf8))
  }

  @Test
  func oneLineHasNoLegend() throws {
    for seed in HealthCards.welcomeSeed {
      #expect(seed.spec.legend.isEmpty)
    }
    // A series hidden behind its formula: one line.
    let trendOnly = try spec(
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "Heart Rate", "hidden": true}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}]}"#
    )
    #expect(trendOnly.legend.isEmpty)
  }

  @Test
  func morningWeightsLabels() throws {
    let morningWeight = try spec(
      #"{"version": 1, "display": {"name": "Morning Weight", "symbol": "scalemass.fill", "color": "purple"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}, "label": "First weigh-in before noon"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": "7-day rolling average"}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#
    )
    #expect(
      morningWeight.legend == [
        CardLegendLine(mark: .series(.circle), label: "First weigh-in before noon"),
        CardLegendLine(mark: .formula, label: "7-day rolling average"),
      ])
  }

  @Test
  func unlabeledLinesAreNamedForWhatTheyAre() throws {
    let hrv = try spec(
      #"{"version": 1, "display": {"name": "HRV"}, "series": [{"type": "HeartRateVariabilitySDNN"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "range": "M", "chart": {"style": "dots"}}"#
    )
    #expect(hrv.legend.map(\.label) == ["Heart Rate Variability", "7-point moving average"])

    // Hidden series leave the legend; the visible ones are marked by their place among them.
    let gap = try spec(
      #"{"version": 1, "display": {"name": "Gap"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}, "hidden": true}, {"type": "Resting Heart Rate"}, {"type": "Walking Heart Rate Average"}], "formulas": [{"id": "gap", "kind": "difference", "of": ["a", "b"]}], "bucket": "night", "range": "M"}"#
    )
    #expect(
      gap.legend == [
        CardLegendLine(mark: .series(.circle), label: "Resting Heart Rate"),
        CardLegendLine(mark: .series(.square), label: "Walking Heart Rate Average"),
        CardLegendLine(mark: .formula, label: "Heart Rate − Resting Heart Rate"),
      ])
  }

  @Test
  func seriesMarksFadeByPlace() {
    #expect(CardSeriesMark.allCases.map(\.opacity) == [1, 0.6, 0.4, 0.25])
    #expect(CardSeriesMark(index: 7) == .diamond)
  }
}
