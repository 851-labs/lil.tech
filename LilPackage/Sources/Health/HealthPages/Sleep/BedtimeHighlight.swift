import Charts
import Dependencies
import HealthDatabase
import SwiftUI

/// Bedtime consistency (851-3103): last night's bedtime against the last two weeks' average, a
/// bar a night from its bedtime down, last night's in Sleep's indigo, the average a teal line.
struct BedtimeHighlight: View {
  let bedtime: BedtimeConsistency
  @Dependency(\.calendar) private var calendar

  var body: some View {
    SleepHighlightRow(
      title: "Sleep", systemImage: "bed.double.fill", color: SleepHighlightStyle.sleep,
      sentence: Self.sentence(bedtime)
    ) {
      chart
      HStack(alignment: .top, spacing: 24) {
        value("Average Bedtime", bedtime.average, color: SleepHighlightStyle.average)
        value("Last Night's Bedtime", bedtime.lastNight.bedtime, color: SleepHighlightStyle.sleep)
        Spacer(minLength: 0)
      }
    }
  }

  static func sentence(_ bedtime: BedtimeConsistency) -> String {
    let difference = bedtime.minutesFromAverage
    // Within 5 minutes reads as the same time.
    guard abs(difference) >= 5 else {
      return "Last night, your bedtime was about the same as usual."
    }
    let way = difference < 0 ? "earlier" : "later"
    return
      "Last night, your bedtime was \(SleepHighlightStyle.minutes(difference)) \(way) than usual."
  }

  private func value(_ label: String, _ hours: Double, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(SleepHighlightStyle.clockTime(hours, calendar: calendar))
        .font(.system(.title2, design: .rounded).bold())
        .foregroundStyle(color)
    }
  }

  /// Bedtimes on a clock-time axis, earlier at the top, as Sleep's W and M charts have them
  /// (851-3098): each bar runs from its bedtime down to the axis's end, so a later bedtime starts
  /// lower. A slot for each of the 14 days, by the page's calendar.
  private var chart: some View {
    let times = bedtime.nights.map(\.bedtime)
    // Sleep's clock-time axis (851-3098), around the bedtimes, with room under the latest for
    // its bar.
    let axis = SleepClock.axis(
      times.isEmpty ? [] : [(times.min() ?? 0) - 0.25, (times.max() ?? 0) + 0.5])
    let bottom = axis.domain.upperBound
    let end =
      calendar.date(byAdding: .day, value: BedtimeConsistency.days, to: bedtime.firstDay)
      ?? bedtime.firstDay
    return Chart {
      ForEach(bedtime.nights, id: \.day) { night in
        let slot = SleepClock.slot(night.day, ratio: 0.6, unit: .day, calendar: calendar)
        RectangleMark(
          xStart: .value("Start", slot.start), xEnd: .value("End", slot.end),
          yStart: .value("Bedtime", -night.bedtime), yEnd: .value("Bottom", -bottom)
        )
        .foregroundStyle(
          night.day == bedtime.lastNight.day
            ? SleepHighlightStyle.sleep : SleepHighlightStyle.earlier
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
      }
      RuleMark(y: .value("Average", -bedtime.average))
        .foregroundStyle(SleepHighlightStyle.average)
        .lineStyle(StrokeStyle(lineWidth: 2))
    }
    .chartXScale(domain: bedtime.firstDay...end)
    .chartXAxis(.hidden)
    .chartYScale(domain: -axis.domain.upperBound ... -axis.domain.lowerBound)
    .chartYAxis {
      AxisMarks(position: .trailing, values: axis.marks.map { -$0 }) { value in
        AxisGridLine()
        AxisValueLabel {
          if let hours = value.as(Double.self) {
            Text(SleepClock.label(-hours, calendar: calendar))
          }
        }
      }
    }
    .frame(height: SleepHighlightStyle.chartHeight)
  }
}
