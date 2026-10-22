import Charts
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SwiftUI

/// One highlight: what changed, in a sentence, and a chart of it.
struct HighlightCard: View {
  let highlight: Highlight
  let type: HealthDataType

  private var color: Color { type.category?.color ?? .accentColor }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HealthTypeLabel(type: type)
        .font(.headline)
      Text(HighlightText.sentence(highlight, type: type))
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      switch highlight.kind {
      case .week: comparison
      case .trend: trend
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
  }

  /// The two weeks' averages as bars, this week in the category's color. Each row has its own
  /// line above its bar, the week's name and its average, so neither can run into the other bar
  /// (851-2824): Charts placed the names as axis labels, between the bars, where they collided.
  private var comparison: some View {
    // Both bars on one scale, the longer one full width.
    let longest = max(highlight.previous, highlight.current)
    return VStack(alignment: .leading, spacing: 8) {
      // Rolling weeks ending yesterday, as the sentence says, not calendar weeks.
      comparisonRow(
        "7 Days Before", highlight.previous, longest: longest, color: Self.earlierColor)
      comparisonRow("Last 7 Days", highlight.current, longest: longest, color: color)
    }
  }

  private func comparisonRow(
    _ label: String, _ value: Double, longest: Double, color: some ShapeStyle
  ) -> some View {
    // Nothing for a week of nothing, or a value that isn't one.
    let share = longest > 0 && value > 0 ? min(value / longest, 1) : 0
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(label)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        // The average stays whole; the name gives way.
        Text(HighlightText.text(value, type))
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
          .layoutPriority(1)
      }
      .font(.caption)
      GeometryReader { proxy in
        // At least a dot, so a week of very little still shows.
        Capsule()
          .fill(color)
          .frame(width: share > 0 ? max(proxy.size.width * share, Self.barHeight) : 0)
      }
      .frame(height: Self.barHeight)
    }
  }

  private static let barHeight: CGFloat = 18
  /// The earlier period, in both kinds of highlight.
  private static let earlierColor = Color.gray.opacity(0.35)

  /// Each week's average, the last 4 in color, with both periods' averages as lines.
  private var trend: some View {
    // Weeks by position from the first, 7 days apart: a calendar-week axis would bin them wrong.
    let first = highlight.points.first?.day ?? highlight.recentStart
    let index = { (day: Date) in Int((day.timeIntervalSince(first) / (7 * 86_400)).rounded()) }
    // Around the values, not from zero, so the change shows.
    let values = highlight.points.map(\.value) + [highlight.current, highlight.previous]
    let (low, high) = (values.min() ?? 0, values.max() ?? 1)
    let floor = max(0, low - (high - low) * 0.5 - 1)
    return Chart {
      ForEach(highlight.points, id: \.day) { week in
        BarMark(
          x: .value("Week", String(index(week.day))), yStart: .value("Floor", floor),
          yEnd: .value("Average", week.value), width: .ratio(0.7)
        )
        .foregroundStyle(week.day >= highlight.recentStart ? color : Self.earlierColor)
      }
      RuleMark(y: .value("Before", highlight.previous))
        .foregroundStyle(Color.gray)
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
      RuleMark(y: .value("Lately", highlight.current))
        .foregroundStyle(color)
    }
    .chartXAxis(.hidden)
    // A slot for every week, with data or not.
    .chartXScale(domain: (0...(highlight.points.last.map { index($0.day) } ?? 15)).map(String.init))
    .chartYAxis {
      AxisMarks(position: .trailing) { value in
        AxisGridLine()
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(MetricFormat.value(number, unit: type.unit, typeID: type.id).number)
          }
        }
      }
    }
    .chartYScale(domain: floor...(high + (high - low) * 0.2 + 1))
    .frame(height: 120)
  }
}

/// How highlights read.
enum HighlightText {
  static func sentence(_ highlight: Highlight, type: HealthDataType) -> String {
    // Each with its own unit: one can be in km and the other in m.
    let value = text(highlight.current, type)
    let before = text(highlight.previous, type)
    let perDay = type.aggregation?.isCumulative == true ? " a day" : ""
    switch highlight.kind {
    case .week:
      let change =
        switch highlight.direction {
        case .up: "up from \(before) the week before"
        case .down: "down from \(before) the week before"
        case .same: "about the same as the week before"
        }
      return "\(type.name) averaged \(value)\(perDay) over the last 7 days, \(change)."
    case .trend:
      let way = highlight.current < highlight.previous ? "down" : "up"
      return
        "\(type.name) has been trending \(way): \(value)\(perDay) on average over the last 4 weeks, against \(before) in the 12 before."
    }
  }

  /// A value with its unit, if it has one.
  static func text(_ value: Double, _ type: HealthDataType) -> String {
    let (number, unit) = MetricFormat.value(value, unit: type.unit, typeID: type.id)
    return unit.isEmpty ? number : "\(number) \(unit)"
  }
}
