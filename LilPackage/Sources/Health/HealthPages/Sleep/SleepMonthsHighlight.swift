import HealthDatabase
import SwiftUI

/// This month against last month (851-3109): their average time asleep, as two bars on one
/// scale, this month in Sleep's indigo, as Summary compares weeks (`ComparisonBars`).
struct SleepMonthsHighlight: View {
  let months: SleepMonthComparison

  var body: some View {
    SleepHighlightRow(
      title: "Sleep", systemImage: "bed.double.fill", color: SleepHighlightStyle.sleep,
      sentence: Self.sentence(months)
    ) {
      ComparisonBars(
        earlier: .init(
          "Last Month", value: months.lastMonthAverage,
          text: SleepFormat.duration(months.lastMonthAverage),
          color: SleepHighlightStyle.earlier),
        recent: .init(
          "This Month", value: months.thisMonthAverage,
          text: SleepFormat.duration(months.thisMonthAverage), color: SleepHighlightStyle.sleep))
    }
  }

  static func sentence(_ months: SleepMonthComparison) -> String {
    switch months.direction {
    case .up: "You're averaging more sleep this month than last month."
    case .down: "You're averaging less sleep this month than last month."
    case .same:
      "You're averaging about the same amount of sleep this month compared to last month."
    }
  }
}
