import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health state-of-mind` and `assessments`' text (851-4160): each log's feelings and what
// they were about, each assessment's risk, score and answers, and what's left out past the cap.
// Synthetic data only.
@Suite struct MentalWellbeingTextTests {
  @Test func listsEachLog() {
    let result = HealthStateOfMindResult(
      timeZone: "UTC", range: "W", start: "2026-10-14T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 3,
      logs: [
        HealthStateOfMindItem(
          time: "2026-10-19T23:30:00+00:00", kind: "Daily Mood", valence: 0.95,
          classification: "Very Pleasant", labels: ["Joyful", "Excited"],
          associations: ["Friends", "Travel"], source: "Health"),
        HealthStateOfMindItem(
          time: "2026-10-18T12:15:00+00:00", kind: "Momentary Emotion", valence: -1,
          classification: "Very Unpleasant", labels: [], associations: [],
          source: "Test Apple Watch"),
      ])
    #expect(
      result.text == """
        State of Mind, W: 2026-10-14 to 2026-10-20 (UTC)
        3 logs

          2026-10-19 23:30   Very Pleasant (0.95) · Daily Mood · Joyful, Excited · about Friends, Travel
          2026-10-18 12:15   Very Unpleasant (-1) · Momentary Emotion

        Showing the 2 most recent logs.

        """)
  }

  @Test func saysWhenThereAreNoLogs() {
    let result = HealthStateOfMindResult(
      timeZone: "UTC", range: "D", start: "2026-10-17T00:00:00+00:00",
      end: "2026-10-18T00:00:00+00:00", count: 0, logs: [])
    #expect(
      result.text == """
        State of Mind, D: 2026-10-17 to 2026-10-17 (UTC)
        0 logs

        """)
  }

  @Test func listsEachAssessment() {
    let result = HealthAssessmentsResult(
      timeZone: "UTC", range: "M", start: "2026-09-21T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 1,
      assessments: [
        HealthAssessmentItem(
          type: "HKScoredAssessmentTypeIdentifierGAD7", name: "Anxiety Risk (GAD-7)",
          time: "2026-10-15T10:00:00+00:00", score: 8, maximumScore: 21, risk: "Mild",
          answers: [
            "Several days", "Several days", "More than half the days", "Not at all",
            "Several days", "More than half the days", "Several days",
          ])
      ])
    #expect(
      result.text == """
        Assessments, M: 2026-09-21 to 2026-10-20 (UTC)
        1 assessment

          2026-10-15 10:00   Anxiety Risk (GAD-7)   Mild, score 8 of 21
              Several days · Several days · More than half the days · Not at all · Several days · More than half the days · Several days

        """)
  }
}
