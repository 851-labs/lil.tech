import Charts
import HealthCatalog
import HealthDatabase
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

  /// The two weeks' averages as bars, this week in the category's color.
  private var comparison: some View {
    Chart {
      bar("Last Week", highlight.previous, color: Color.gray.opacity(0.35))
      bar("This Week", highlight.current, color: color)
    }
    .chartXAxis(.hidden)
    .chartYAxis {
      AxisMarks { _ in AxisValueLabel() }
    }
    .frame(height: 70)
  }

  private func bar(_ label: String, _ value: Double, color: some ShapeStyle) -> some ChartContent {
    let (number, unit) = MetricFormat.value(value, unit: type.unit, typeID: type.id)
    return BarMark(x: .value("Average", value), y: .value("Week", label), height: 18)
      .foregroundStyle(color)
      .clipShape(Capsule())
      .annotation(position: .trailing) {
        Text("\(number) \(unit)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
  }

  /// Each week's average, the last 4 in color, with both periods' averages as lines.
  private var trend: some View {
    let recentStart = highlight.points.suffix(4).first?.day ?? .distantFuture
    // Around the values, not from zero, so the change shows.
    let values = highlight.points.map(\.value) + [highlight.current, highlight.previous]
    let (low, high) = (values.min() ?? 0, values.max() ?? 1)
    let floor = max(0, low - (high - low) * 0.5 - 1)
    return Chart {
      ForEach(highlight.points, id: \.day) { week in
        BarMark(
          x: .value("Week", week.day, unit: .weekOfYear), yStart: .value("Floor", floor),
          yEnd: .value("Average", week.value)
        )
        .foregroundStyle(week.day >= recentStart ? color : Color.gray.opacity(0.35))
      }
      RuleMark(y: .value("Before", highlight.previous))
        .foregroundStyle(Color.gray)
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
      RuleMark(y: .value("Lately", highlight.current))
        .foregroundStyle(color)
    }
    .chartXAxis(.hidden)
    .chartYAxis {
      AxisMarks(position: .trailing)
    }
    .chartYScale(domain: floor...(high + (high - low) * 0.2 + 1))
    .frame(height: 120)
  }
}

/// How highlights read.
enum HighlightText {
  static func sentence(_ highlight: Highlight, type: HealthDataType) -> String {
    let (number, unit) = MetricFormat.value(highlight.current, unit: type.unit, typeID: type.id)
    let (before, _) = MetricFormat.value(highlight.previous, unit: type.unit, typeID: type.id)
    let value = unit.isEmpty ? number : "\(number) \(unit)"
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
}
