import Charts
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import SwiftUI

/// One metric in a form row, on Summary and the category pages: its name, when it's from, its
/// latest value and a week's chart. Its height is the same with a value, without data ("No
/// Data"), or while it loads (no summary yet, "–"), so nothing moves as Summary loads or a
/// metric's data arrives (851-3092). A row with data but no latest value to show (a medication's)
/// is its name and date. Sound levels show their week's exposure in place of a value, over the
/// limit or not, beside each day's range, as Health's cards do (851-3100).
struct MetricRow: View {
  let type: HealthDataType
  /// Nil while it loads.
  let summary: MetricSummary?
  /// The label's and the chart's.
  let color: Color
  let now: Date
  let calendar: Calendar

  /// In `color`, or the type's own (`HealthDataType.color`) without one. A category
  /// page passes its own, so a type listed under two categories takes the page's.
  init(
    type: HealthDataType, summary: MetricSummary?, color: Color? = nil, now: Date,
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
        if let summary, let date = summary.latestDate {
          Text(
            MetricFormat.date(date, isDay: summary.isDailyTotal, now: now, calendar: calendar)
          )
          .foregroundStyle(.secondary)
        }
      }
      if let summary, let exposure = summary.soundExposure {
        HStack(alignment: .bottom) {
          SoundExposureStatus(exposure: exposure)
          Spacer()
          Sparkline(days: summary.days, isTotals: false, isRanges: true, color: color)
            .frame(width: 120, height: 36)
        }
      } else if let summary, let value = summary.latestValue {
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
      } else if summary == nil || summary?.hasData == false {
        // Loading, or no data: the value's line all the same, the chart's place kept.
        HStack(alignment: .bottom) {
          if summary == nil {
            Text("–")
              .font(.system(.title, design: .rounded).bold())
              .foregroundStyle(.secondary)
              .accessibilityLabel("Loading")
          } else {
            Text("No Data")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Color.clear
            .frame(width: 120, height: 36)
        }
      }
    }
    .padding(.vertical, 6)
  }
}

/// "7-Day Exposure" and whether it's within the limit: "OK" by a green dot, or "Loud" by a
/// yellow one, as Health and the Watch's Noise app put it. Two short lines, so the row keeps the
/// height of one with a value.
struct SoundExposureStatus: View {
  let exposure: SoundExposure

  private var status: String { exposure.isOverLimit ? "Loud" : "OK" }
  /// Rounded down, so a week just under the limit never reads as 100% and OK.
  private var share: String {
    exposure.dose.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("7-Day Exposure")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(spacing: 5) {
        Circle()
          .fill(exposure.isOverLimit ? Color.yellow : .green)
          .frame(width: 8, height: 8)
        Text(status)
          .font(.system(.title2, design: .rounded).bold())
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("7-Day Exposure")
    .accessibilityValue("\(status), \(share) of the weekly limit")
  }
}

/// A week at a glance: bars for daily totals, a line for daily averages, or each day's range from
/// its lowest to its highest value.
struct Sparkline: View {
  let days: [DailyValue]
  let isTotals: Bool
  var isRanges = false
  let color: Color

  var body: some View {
    Chart(days, id: \.day) { day in
      if isRanges {
        // A capsule, and a dot for a day whose values were all the same. Days without a range
        // are left out rather than drawn another way.
        if let minimum = day.minimum, let maximum = day.maximum {
          RuleMark(
            x: .value("Day", day.day, unit: .day), yStart: .value("Lowest", minimum),
            yEnd: .value("Highest", maximum)
          )
          .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
          .foregroundStyle(color)
        }
      } else if isTotals {
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
    .chartYScale(domain: .automatic(includesZero: !isRanges))
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
  }
}
