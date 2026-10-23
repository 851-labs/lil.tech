import Charts
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SwiftUI

/// One metric with data, in a form row, on Summary and the category pages: its name, when it's
/// from, its latest value and a week's chart.
struct MetricRow: View {
  let type: HealthDataType
  let summary: MetricSummary
  /// The label's and the chart's.
  let color: Color
  let now: Date
  let calendar: Calendar

  /// In `color`, or the type's own (`HealthDataType.color`) without one. A category
  /// page passes its own, so a type listed under two categories takes the page's.
  init(
    type: HealthDataType, summary: MetricSummary, color: Color? = nil, now: Date,
    calendar: Calendar
  ) {
    self.type = type
    self.summary = summary
    self.color = color ?? type.color
    self.now = now
    self.calendar = calendar
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        HealthTypeLabel(type: type, color: color)
          .font(.headline)
        Spacer()
        if let date = summary.latestDate {
          Text(
            MetricFormat.date(date, isDay: summary.isDailyTotal, now: now, calendar: calendar)
          )
          .foregroundStyle(.secondary)
        }
      }
      if let value = summary.latestValue {
        HStack(alignment: .bottom) {
          let (number, unit) = MetricFormat.value(value, unit: summary.unit, typeID: type.id)
          HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(number)
              .font(.system(.title, design: .rounded).bold())
            Text(unit)
              .font(.callout.weight(.medium))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Sparkline(days: summary.days, isTotals: summary.isDailyTotal, color: color)
            .frame(width: 120, height: 36)
        }
      }
    }
    .padding(.vertical, 6)
  }
}

/// A metric's row while its value loads: its name, and "–" where its value and chart go, as tall
/// as a row with data (`MetricRow`), so nothing moves when it loads (851-3092).
struct MetricRowPlaceholder: View {
  let type: HealthDataType

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HealthTypeLabel(type: type)
        .font(.headline)
      HStack(alignment: .bottom) {
        Text("–")
          .font(.system(.title, design: .rounded).bold())
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Spacer()
        // The chart's place.
        Color.clear
          .frame(width: 120, height: 36)
      }
    }
    .padding(.vertical, 6)
  }
}

/// A week at a glance: bars for daily totals, a line for daily averages.
struct Sparkline: View {
  let days: [DailyValue]
  let isTotals: Bool
  let color: Color

  var body: some View {
    Chart(days, id: \.day) { day in
      if isTotals {
        BarMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(color.opacity(0.8))
      } else {
        LineMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(color)
        PointMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(color)
          .symbolSize(12)
      }
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
  }
}
