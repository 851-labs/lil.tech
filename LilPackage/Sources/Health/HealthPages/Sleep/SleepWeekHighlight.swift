import Charts
import Dependencies
import HealthDatabase
import SwiftUI

/// The last 7 days (851-3111): each night's time asleep as a bar, a slot a day by weekday, with
/// their average as a teal line, as bedtime's is.
struct SleepWeekHighlight: View {
  let week: SleepWeekAverage
  @Dependency(\.calendar) private var calendar

  var body: some View {
    SleepHighlightRow(
      title: "Sleep", systemImage: "bed.double.fill", color: SleepHighlightStyle.sleep,
      sentence: Self.sentence(week)
    ) {
      chart
    }
  }

  static func sentence(_ week: SleepWeekAverage) -> String {
    "You slept an average of \(SleepFormat.duration(week.average)) over the last 7 days."
  }

  /// A slot a day, by weekday, so every night has its place, with sleep or not.
  private var chart: some View {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    let name = { (day: Date) in day.formatted(style.weekday(.abbreviated)) }
    let days = (0..<SleepWeekAverage.days).compactMap {
      calendar.date(byAdding: .day, value: $0, to: week.firstDay)
    }
    return Chart {
      ForEach(week.nights, id: \.day) { night in
        BarMark(
          x: .value("Night", name(night.day)), y: .value("Hours", night.asleep / 3600),
          width: .ratio(0.6)
        )
        .foregroundStyle(SleepHighlightStyle.sleep)
        .clipShape(RoundedRectangle(cornerRadius: 3))
      }
      RuleMark(y: .value("Average", week.average / 3600))
        .foregroundStyle(SleepHighlightStyle.average)
        .lineStyle(StrokeStyle(lineWidth: 2))
    }
    .chartXScale(domain: days.map(name))
    // Weekdays without grid lines between them.
    .chartXAxis { AxisMarks { AxisValueLabel() } }
    .chartYAxis {
      AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel { if let hours = value.as(Double.self) { Text("\(Int(hours)) hr") } }
      }
    }
    .frame(height: SleepHighlightStyle.chartHeight)
  }
}
