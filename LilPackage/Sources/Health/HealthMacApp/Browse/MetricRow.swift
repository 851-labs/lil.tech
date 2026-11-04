import Charts
import Dependencies
import HealthCards
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
  /// Whose units the value is in (851-3116).
  @Dependency(\.locale) private var locale

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
          let (number, unit) = MetricFormat.value(
            value, unit: summary.unit, typeID: type.id, locale: locale)
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

extension Sparkline {
  /// A metric's week, ending with its latest day.
  init(days: [DailyValue], style: HealthDataType.ChartStyle, color: Color, calendar: Calendar) {
    let week = HealthDatabase.weekEnding(on: days.last?.day ?? .distantPast, calendar: calendar)
    self.init(
      points: days.map {
        SparklinePoint(start: $0.day, value: $0.value, minimum: $0.minimum, maximum: $0.maximum)
      }, style: style, color: color, domain: week.lowerBound...week.upperBound, unit: .day)
  }
}
