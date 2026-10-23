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
          Sparkline(
            days: summary.days, style: type.chartStyle ?? .ranges, color: color, calendar: calendar
          )
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
          // Every quantity type has a style: bars for totals (851-3097).
          Sparkline(
            days: summary.days, style: type.chartStyle ?? .ranges, color: color, calendar: calendar
          )
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

/// A week at a glance, in the type's chart style, as iPad Health's rows draw it (851-3101): the
/// days in gray and the latest in `color`. Bars are each day's total, from 0 (or below it, for
/// values that are); ranges its lowest to its highest reading, and dots and a line through them
/// its average, on an axis fitted to them, as Metric Detail's are (`fittedDomain`), the line's latest a hollow circle. Always the
/// whole week, its latest day at the right, however few days have data.
struct Sparkline: View {
  let days: [DailyValue]
  let style: HealthDataType.ChartStyle
  let color: Color
  let calendar: Calendar

  /// The days before the latest.
  private static let gray = Color.gray.opacity(0.55)

  var body: some View {
    Chart(days, id: \.day) { day in
      let isLatest = day.day == days.last?.day
      switch style {
      case .bars:
        BarMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(isLatest ? color : Self.gray)
      case .ranges:
        // A capsule from the lowest to the highest reading: a dot for a day of one.
        RuleMark(
          x: .value("Day", day.day, unit: .day),
          yStart: .value("Lowest", day.minimum ?? day.value),
          yEnd: .value("Highest", day.maximum ?? day.value)
        )
        .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
        .foregroundStyle(isLatest ? color : Self.gray)
      case .dots:
        PointMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(isLatest ? color : Self.gray)
          .symbolSize(30)
      case .line:
        LineMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .foregroundStyle(Self.gray)
          .lineStyle(StrokeStyle(lineWidth: 2))
        PointMark(x: .value("Day", day.day, unit: .day), y: .value("Value", day.value))
          .symbol {
            if isLatest {
              // Hollow: the row's fill inside, over the line.
              Circle()
                .strokeBorder(color, lineWidth: 2)
                .background(Circle().fill(.background.secondary))
                .frame(width: 9, height: 9)
            } else {
              Circle()
                .fill(Self.gray)
                .frame(width: 4.5, height: 4.5)
            }
          }
      }
    }
    .chartXScale(domain: week)
    .chartYScale(domain: yDomain)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
  }

  /// The week the summary's days cover, ending with the latest's.
  private var week: ClosedRange<Date> {
    let week = HealthDatabase.weekEnding(on: days.last?.day ?? .distantPast, calendar: calendar)
    return week.lowerBound...week.upperBound
  }

  private var yDomain: ClosedRange<Double> {
    switch style {
    case .bars:
      // The highest at the top: a sparkline has no axis to round up to.
      let low = min(days.map(\.value).min() ?? 0, 0)
      let high = max(days.map(\.value).max() ?? 0, 0)
      return low...(high > low ? high : low + 1)
    case .ranges:
      // Fitted, unlike the page's from 0: a sound level's 60–75 dB would be a sliver at the top.
      return fittedDomain(days.flatMap { [$0.minimum ?? $0.value, $0.maximum ?? $0.value] })
        ?? 0...1
    case .dots, .line:
      return fittedDomain(days.map(\.value)) ?? 0...1
    }
  }
}
