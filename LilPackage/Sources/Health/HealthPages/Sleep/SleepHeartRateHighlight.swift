import Charts
import Dependencies
import HealthDatabase
import SwiftUI

/// Heart Rate: Sleep (851-3110): last night's heart rate while asleep, a range bar every 15
/// minutes, in the Heart color, with the highest and lowest marked.
struct SleepHeartRateHighlight: View {
  let heartRate: SleepHeartRate
  @Dependency(\.calendar) private var calendar

  var body: some View {
    SleepHighlightRow(
      title: "Heart Rate: Sleep", systemImage: "heart.fill", color: SleepHighlightStyle.heart,
      sentence: Self.sentence(heartRate)
    ) {
      chart
    }
  }

  static func sentence(_ heartRate: SleepHeartRate) -> String {
    let (low, high) = (Int(heartRate.minimum.rounded()), Int(heartRate.maximum.rounded()))
    return low == high
      ? "While you were sleeping, your heart rate was \(low) beats per minute."
      : "While you were sleeping, your heart rate ranged from \(low) to \(high) beats per minute."
  }

  private var chart: some View {
    let ranges = heartRate.ranges
    // The first range with the night's highest, and with its lowest, labeled.
    let highest = ranges.firstIndex { $0.maximum == heartRate.maximum }
    let lowest = ranges.firstIndex { $0.minimum == heartRate.minimum }
    let half = SleepHeartRate.interval / 2
    return Chart(Array(ranges.enumerated()), id: \.offset) { index, range in
      // At least a beat tall, so a range of one reading shows.
      // In its range's middle, or at the night's end for a last range cut short by waking.
      BarMark(
        x: .value("Time", min(range.start.addingTimeInterval(half), heartRate.end)),
        yStart: .value("Minimum", range.minimum - (range.minimum == range.maximum ? 0.5 : 0)),
        yEnd: .value("Maximum", range.maximum + (range.minimum == range.maximum ? 0.5 : 0)),
        width: .fixed(5)
      )
      .foregroundStyle(SleepHighlightStyle.heart)
      .clipShape(Capsule())
      // Kept inside the chart, for a first or last range.
      .annotation(position: .top, spacing: 2, overflowResolution: Self.inside) {
        if index == highest { label("MAX", heartRate.maximum) }
      }
      .annotation(position: .bottom, spacing: 2, overflowResolution: Self.inside) {
        if index == lowest { label("MIN", heartRate.minimum) }
      }
    }
    .chartXScale(domain: heartRate.start...heartRate.end)
    .chartXAxis {
      AxisMarks(
        values: SleepClock.hourMarks(from: heartRate.start, to: heartRate.end, calendar: clock)
      ) { value in
        AxisGridLine()
        AxisValueLabel {
          if let date = value.as(Date.self) { Text(SleepClock.hourLabel(date, calendar: clock)) }
        }
      }
    }
    // Room above and below for the labels: a label's height is about an eighth of the plot, so
    // a sixth of the range on each side, and at least 8 beats.
    .chartYScale(domain: (heartRate.minimum - padding)...(heartRate.maximum + padding))
    .chartYAxis {
      AxisMarks(position: .trailing, values: .automatic(desiredCount: 3))
    }
    .frame(height: SleepHighlightStyle.chartHeight + 20)
  }

  /// The page's calendar in the night's zone: its hours are marked on the night's own clock, as
  /// its stages' are (851-4178).
  private var clock: Calendar {
    var clock = calendar
    if let timeZone = heartRate.timeZone { clock.timeZone = timeZone }
    return clock
  }

  private var padding: Double { max(8, (heartRate.maximum - heartRate.minimum) / 6 + 4) }

  private static let inside = AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)

  private func label(_ name: String, _ value: Double) -> some View {
    HStack(spacing: 2) {
      Text(name)
        .foregroundStyle(.secondary)
      Text("\(Int(value.rounded()))")
    }
    .font(.caption2.weight(.semibold))
  }
}
