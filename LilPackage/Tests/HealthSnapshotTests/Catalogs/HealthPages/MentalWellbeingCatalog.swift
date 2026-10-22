#if os(macOS)
  import Foundation
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // State of Mind (`StateOfMindContent`) and an assessment's history (`ScoredAssessmentsContent`):
  // made-up logs and assessments before `previewNow`. Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: mentalWellbeingCatalog.selectedStates)
    func mentalWellbeing(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let mentalWellbeingCatalog = StateCatalog(
    "Mental Wellbeing", width: 680, minHeight: 760,
    states: [
      CatalogState("State of Mind") { stateOfMind(.loaded(logs)) },
      // Logs, but none in the last four weeks.
      CatalogState("State of Mind, none recently") {
        stateOfMind(.loaded([log(10, hoursAgo: 24 * 60, valence: 0.2, labels: [7])]))
      },
      CatalogState("State of Mind, at the limit") {
        stateOfMind(.loaded(Array(logs.prefix(3))), limit: 3)
      },
      CatalogState("No State of Mind logs") { stateOfMind(.loaded([])) },
      CatalogState("State of Mind loading") { stateOfMind(.loading) },
      CatalogState("State of Mind failed") {
        stateOfMind(.failed("The database couldn't be read."))
      },
      // An assessment's history.
      CatalogState("GAD-7", width: 640, minHeight: 600) { assessments(.gad7, .loaded(gad7)) },
      CatalogState("PHQ-9, severe", width: 640, minHeight: 600) {
        assessments(.phq9, .loaded(phq9))
      },
      // As if these were the most it holds: it says the list is cut short.
      CatalogState("GAD-7, at the limit", width: 640, minHeight: 600) {
        assessments(.gad7, .loaded(gad7), limit: gad7.count)
      },
      CatalogState("No assessments", width: 640, minHeight: 600) {
        assessments(.gad7, .loaded([]))
      },
      CatalogState("Assessments loading", width: 640, minHeight: 600) {
        assessments(.gad7, .loading)
      },
      CatalogState("Assessments failed", width: 640, minHeight: 600) {
        assessments(.phq9, .failed("The database couldn't be read."))
      },
    ])

  private func log(
    _ index: Int, hoursAgo: Double, valence: Double, kind: Int = 1, labels: [Int] = [],
    associations: [Int] = []
  ) -> HealthStateOfMind {
    let start = previewNow.addingTimeInterval(-hoursAgo * 3_600).unixMilliseconds
    let classification = min(7, max(1, Int(((valence + 1) / 2 * 6).rounded()) + 1))
    return HealthStateOfMind(
      id: "6f1c2a40-0000-4000-8000-\(String(format: "%012d", index))", startDate: start,
      endDate: start, kind: kind, valence: valence, valenceClassification: classification,
      labels: "\(labels)", associations: "\(associations)", sourceName: "Health",
      sourceBundleID: "com.apple.Health")
  }

  private let logs = [
    log(1, hoursAgo: 2, valence: 0.7, labels: [17, 7], associations: [7, 6]),
    log(2, hoursAgo: 9, valence: -0.5, labels: [29, 31], associations: [17]),
    log(3, hoursAgo: 26, valence: 0.3, kind: 2, labels: [8], associations: [5]),
    log(4, hoursAgo: 50, valence: 0.9, labels: [13, 15, 21], associations: [16, 7]),
    log(5, hoursAgo: 75, valence: -0.85, labels: [27, 22, 34], associations: [8, 12]),
    log(6, hoursAgo: 120, valence: 0.05, kind: 2, labels: [36], associations: [18]),
    log(7, hoursAgo: 200, valence: 0.55, labels: [24, 26], associations: [9]),
    log(8, hoursAgo: 330, valence: -0.2, labels: [19], associations: [15]),
    log(9, hoursAgo: 500, valence: 0.4, kind: 2, labels: [38], associations: [17, 5]),
  ]

  private func assessment(
    _ index: Int, _ kind: AssessmentKind, daysAgo: Double, score: Int, risk: Int
  ) -> HealthScoredAssessment {
    let start = previewNow.addingTimeInterval(-daysAgo * 86_400).unixMilliseconds
    return HealthScoredAssessment(
      id: "6f1c2a40-0000-4000-8001-\(String(format: "%012d", index))", type: kind.rawValue,
      startDate: start, endDate: start, score: score, risk: risk,
      answers: "[1,1,0,1,2,0,1]", sourceName: "Health", sourceBundleID: "com.apple.Health")
  }

  private let gad7 = [
    assessment(1, .gad7, daysAgo: 3, score: 6, risk: 2),
    assessment(2, .gad7, daysAgo: 40, score: 11, risk: 3),
    assessment(3, .gad7, daysAgo: 95, score: 16, risk: 4),
    assessment(4, .gad7, daysAgo: 160, score: 4, risk: 1),
  ]

  private let phq9 = [
    assessment(5, .phq9, daysAgo: 10, score: 21, risk: 5),
    assessment(6, .phq9, daysAgo: 70, score: 17, risk: 4),
  ]

  @MainActor
  private func stateOfMind(
    _ state: StateOfMindContent.State, limit: Int = RecentStateOfMindLogs.limit
  ) -> some View {
    NavigationStack {
      StateOfMindContent(state: state, now: previewNow, limit: limit)
    }
  }

  @MainActor
  private func assessments(
    _ kind: AssessmentKind, _ state: ScoredAssessmentsContent.State,
    limit: Int = RecentAssessments.limit
  ) -> some View {
    NavigationStack {
      ScoredAssessmentsContent(
        kind: kind, name: kind == .gad7 ? "Anxiety Risk (GAD-7)" : "Depression Risk (PHQ-9)",
        state: state, limit: limit)
    }
  }
#endif
