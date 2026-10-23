import HealthDatabase
import SwiftUI

/// This month against last month (851-3103): their average time asleep, as two bars on one
/// scale, this month in Sleep's indigo, as Summary's weeks are compared.
struct SleepMonthsHighlight: View {
  let months: SleepMonthComparison

  var body: some View {
    SleepHighlightRow(
      title: "Sleep", systemImage: "bed.double.fill", color: SleepHighlightStyle.sleep,
      sentence: Self.sentence(months)
    ) {
      let longest = max(months.thisMonthAverage, months.lastMonthAverage)
      VStack(alignment: .leading, spacing: 8) {
        row("Last Month", months.lastMonthAverage, longest: longest, SleepHighlightStyle.earlier)
        row("This Month", months.thisMonthAverage, longest: longest, SleepHighlightStyle.sleep)
      }
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

  /// A month's name and average over its bar, so neither runs into the other bar (851-2824).
  private func row(
    _ label: String, _ average: TimeInterval, longest: TimeInterval, _ color: Color
  ) -> some View {
    let share = longest > 0 ? min(average / longest, 1) : 0
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(label)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Text(SleepFormat.duration(average))
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
          .layoutPriority(1)
      }
      .font(.caption)
      GeometryReader { proxy in
        Capsule()
          .fill(color)
          .frame(width: max(proxy.size.width * share, Self.barHeight))
      }
      .frame(height: Self.barHeight)
    }
  }

  private static let barHeight: CGFloat = 18
}
