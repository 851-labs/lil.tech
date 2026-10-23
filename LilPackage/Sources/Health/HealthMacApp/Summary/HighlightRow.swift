import Charts
import Dependencies
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SwiftUI

/// One highlight, in a form row: what changed, in a sentence, and a chart of it.
struct HighlightRow: View {
  let highlight: Highlight
  let type: HealthDataType
  /// Whose units values are in (851-3116).
  @Dependency(\.locale) private var locale

  private var color: Color { type.color }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HealthTypeLabel(type: type)
        .font(.headline)
      Text(HighlightText.sentence(highlight, type: type, locale: locale))
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      switch highlight.kind {
      case .week: comparison
      case .trend: trend
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The two weeks' averages as bars, this week in the category's color.
  private var comparison: some View {
    // Rolling weeks ending yesterday, as the sentence says, not calendar weeks. Sized by their
    // stored values, whose ratio no unit changes.
    ComparisonBars(
      earlier: .init(
        "7 Days Before", value: highlight.previous,
        text: HighlightText.text(highlight.previous, type, locale: locale),
        color: Self.earlierColor),
      recent: .init(
        "Last 7 Days", value: highlight.current,
        text: HighlightText.text(highlight.current, type, locale: locale), color: color))
  }

  /// What values are written in, and so what the trend plots, so its ticks are round in it.
  private var displayUnit: MetricFormat.DisplayUnit {
    MetricFormat.unit(type.unit, typeID: type.id, locale: locale)
  }

  /// The earlier period, in both kinds of highlight.
  private static let earlierColor = ComparisonBars.earlierColor

  /// Each week's average, the last 4 in color, with both periods' averages as lines.
  private var trend: some View {
    // Weeks by position from the first, 7 days apart: a calendar-week axis would bin them wrong.
    let first = highlight.points.first?.day ?? highlight.recentStart
    let index = { (day: Date) in Int((day.timeIntervalSince(first) / (7 * 86_400)).rounded()) }
    // Around the values, not from zero, so the change shows.
    let values = highlight.points.map(\.value) + [highlight.current, highlight.previous]
    let (low, high) = (values.min() ?? 0, values.max() ?? 1)
    // Plotted in the unit the sentence writes them in, so the axis's ticks are round in it
    // (851-3116).
    let shown = displayUnit
    let (current, previous) = (shown.convert(highlight.current), shown.convert(highlight.previous))
    let floor = shown.convert(max(0, low - (high - low) * 0.5 - 1))
    let top = shown.convert(high + (high - low) * 0.2 + 1)
    return Chart {
      ForEach(highlight.points, id: \.day) { week in
        BarMark(
          x: .value("Week", String(index(week.day))), yStart: .value("Floor", floor),
          yEnd: .value("Average", shown.convert(week.value)), width: .ratio(0.7)
        )
        .foregroundStyle(week.day >= highlight.recentStart ? color : Self.earlierColor)
      }
      RuleMark(y: .value("Before", previous))
        .foregroundStyle(Color.gray)
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
      RuleMark(y: .value("Lately", current))
        .foregroundStyle(color)
    }
    .chartXAxis(.hidden)
    // A slot for every week, with data or not.
    .chartXScale(domain: (0...(highlight.points.last.map { index($0.day) } ?? 15)).map(String.init))
    .chartYAxis {
      // A compound unit's ticks at whole inches or pounds, so no two read the same.
      AxisMarks(
        position: .trailing,
        values: shown.compoundTickStride(over: top - floor).map { .stride(by: $0) } ?? .automatic
      ) { value in
        AxisGridLine()
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(shown.format(number))
          }
        }
      }
    }
    .chartYScale(domain: floor...top)
    .frame(height: 120)
  }
}

/// How highlights read.
enum HighlightText {
  static func sentence(_ highlight: Highlight, type: HealthDataType, locale: Locale) -> String {
    let value = text(highlight.current, type, locale: locale)
    let before = text(highlight.previous, type, locale: locale)
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

  /// A value with its unit, if it has one, in `locale`'s units.
  static func text(_ value: Double, _ type: HealthDataType, locale: Locale) -> String {
    let (number, unit) = MetricFormat.value(
      value, unit: type.unit, typeID: type.id, locale: locale)
    return unit.isEmpty ? number : "\(number) \(unit)"
  }
}
