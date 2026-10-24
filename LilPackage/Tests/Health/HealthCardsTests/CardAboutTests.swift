import Foundation
import Testing

@testable import HealthCards

/// About This Card (851-3207): one sentence from the spec, never its labels.
struct CardAboutTests {
  func spec(_ text: String) throws -> CardSpec {
    try CardSpec(inputJSON: Data(text.utf8))
  }

  @Test
  func seedCards() {
    let abouts = HealthCards.welcomeSeed.map(\.spec.about)
    #expect(
      abouts == [
        "Total steps.", "Heart rate range.", "Total active energy.",
        "Total walking + running distance.", "Average resting heart rate.", "Average weight.",
      ])
  }

  @Test
  func exampleCards() throws {
    let examples = try [
      #"{"version": 1, "display": {"name": "Body Temperature"}, "series": [{"type": "Body Temperature"}], "range": "M", "chart": {"style": "line"}}"#,
      #"{"version": 1, "display": {"name": "Sleeping Heart Rate"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "M", "chart": {"style": "line"}}"#,
      #"{"version": 1, "display": {"name": "HRV"}, "series": [{"type": "HeartRateVariabilitySDNN"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "range": "M", "chart": {"style": "dots"}}"#,
      #"{"version": 1, "display": {"name": "Heart Rate Before Sleep"}, "series": [{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "M", "chart": {"style": "dots"}}"#,
      #"{"version": 1, "display": {"name": "Morning Weight"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}, "label": "First weigh-in before noon"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": "7-day rolling average"}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#,
    ].map(spec)
    #expect(
      examples.map(\.about) == [
        "Average body temperature.",
        "Average heart rate while asleep, per night.",
        "Average heart rate variability, with a 7-point moving average.",
        "Average heart rate in the 5 minutes before falling asleep, per night.",
        "First weight reading before noon, per day, with a 7-day moving average.",
      ])
  }

  @Test
  func formulasWindowsAndFilters() throws {
    // Sleeping heart rate above resting: only the difference shows.
    let gap = try spec(
      #"{"version": 1, "display": {"name": "Above Resting"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}, "hidden": true}, {"type": "Resting Heart Rate", "hidden": true}], "formulas": [{"id": "gap", "kind": "difference", "of": ["a", "b"]}], "bucket": "night"}"#
    )
    #expect(
      gap.about
        == "Average heart rate while asleep minus average resting heart rate, per night.")
    let runs = try spec(
      #"{"version": 1, "display": {"name": "Runs"}, "series": [{"type": "Heart Rate", "aggregation": "max", "window": {"kind": "workout", "activities": [37, 13, 46]}, "filter": {"deviceModels": ["Watch"]}}], "bucket": "day"}"#
    )
    #expect(
      runs.about
        == "Highest heart rate during running, cycling or swimming workouts from Watch, per day.")
    let evenings = try spec(
      #"{"version": 1, "display": {"name": "Evenings"}, "series": [{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "timeOfDay", "from": "18:30", "to": "00:00"}}], "chart": {"style": "bars"}}"#
    )
    #expect(evenings.about == "Number of heart rate readings from 18:30 to midnight.")
    #expect(CardSpec.lowercased("VO₂ Max") == "VO₂ max")
    #expect(CardSpec.lowercased("HRV Trend") == "HRV trend")
  }
}
