import Charts
import Foundation
import HealthDatabase
import SwiftUI

// Sleep's charts for W, M and 6M, as Health draws them (851-3098): each night a column at the
// clock times it ran, bedtime at the top, stacked by stage; 6M a bar a week from its average
// bedtime to its average wake. The y-axis is clock time, on the trailing side.

/// Where sleep goes on a chart's clock-time axis.
enum SleepClock {
  /// `date`'s time on the local clock, in hours from the start of `day`, the night's: 11 PM the
  /// evening before is -1, 7:30 AM is 7.5. By the clock, not the time elapsed since midnight, so a
  /// night across a daylight saving change still shows where its clock said (bed at 11 PM, up at
  /// 7 AM), and so does every night after it.
  static func hours(_ date: Date, from day: Date, calendar: Calendar) -> Double {
    let time = calendar.dateComponents([.hour, .minute, .second], from: date)
    let days =
      calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: date)).day ?? 0
    return Double(days * 24 + (time.hour ?? 0)) + Double(time.minute ?? 0) / 60
      + Double(time.second ?? 0) / 3600
  }

  /// The axis's span, in `hours`, from whole marks before the earliest time to after the latest,
  /// with its marks: every 2 hours, or 4 when that's over 12 hours.
  static func axis(_ times: [Double]) -> (domain: ClosedRange<Double>, marks: [Double]) {
    guard let earliest = times.min(), let latest = times.max() else {
      // Nothing to place: the hours a night usually takes.
      return (-2...8, Array(stride(from: -2, through: 8, by: 2)))
    }
    let step: Double = latest - earliest > 12 ? 4 : 2
    let low = (earliest / step).rounded(.down) * step
    let high = max((latest / step).rounded(.up) * step, low + step)
    return (low...high, Array(stride(from: low, through: high, by: step)))
  }

  /// A mark's clock time, "10 PM", "12 AM", in the calendar's locale.
  static func label(_ hours: Double, calendar: Calendar) -> String {
    let hour = (Int(hours.rounded()) % 24 + 24) % 24
    // An hour in GMT, which has no daylight saving gaps, formatted there.
    let style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
      timeZone: .gmt
    ).hour()
    return Date(timeIntervalSince1970: Double(hour) * 3600).formatted(style)
  }
}

/// A night's stretch of one stage, at clock time.
private struct SleepBlock: Identifiable {
  let id: Int
  let day: Date
  let stage: SleepStage
  /// Hours from the start of `day` (`SleepClock`).
  let start: Double
  let end: Double
}

/// A week's average sleep, at clock time, for 6M.
struct SleepWeek: Equatable, Identifiable {
  var id: Date { start }
  /// The start of the week.
  let start: Date
  /// The average time the week's nights fell asleep, and woke, in hours from their days' starts.
  let bedtime: Double
  let wake: Double

  /// Each week with a night, oldest first: its nights' average time asleep, from the first
  /// stretch of sleep to the last, as Health's 6M bars.
  static func weeks(_ nights: [SleepNight], calendar: Calendar) -> [SleepWeek] {
    let spans = nights.compactMap { night -> (week: Date, start: Double, end: Double)? in
      let asleep = night.segments.filter(\.stage.isAsleep)
      guard let start = asleep.map(\.start).min(), let end = asleep.map(\.end).max(),
        let week = calendar.dateInterval(of: .weekOfYear, for: night.day)?.start
      else { return nil }
      return (
        week, SleepClock.hours(start, from: night.day, calendar: calendar),
        SleepClock.hours(end, from: night.day, calendar: calendar)
      )
    }
    return Dictionary(grouping: spans, by: \.week)
      .map { week, spans in
        let count = Double(spans.count)
        return SleepWeek(
          start: week, bedtime: spans.reduce(0) { $0 + $1.start } / count,
          wake: spans.reduce(0) { $0 + $1.end } / count)
      }
      .sorted { $0.start < $1.start }
  }
}

/// W and M: a column per night, from bedtime to waking, a block per stretch of a stage, with a
/// slot for every night of the period.
struct SleepNightsChart: View {
  let period: SleepPeriod
  let calendar: Calendar

  var body: some View {
    let blocks = blocks
    let axis = SleepClock.axis(blocks.flatMap { [$0.start, $0.end] })
    Chart(blocks) { block in
      // Negative, so later is lower: bedtime at the top, as in Health.
      BarMark(
        x: .value("Night", block.day, unit: .day),
        yStart: .value("Start", -block.start), yEnd: .value("End", -block.end),
        width: .ratio(period.range == .week ? 0.3 : 0.6)
      )
      .foregroundStyle(SleepFormat.color(block.stage))
      // Square, so a night's stretches join into one column.
      .cornerRadius(0)
    }
    .chartXScale(domain: period.firstDay...end)
    .chartYScale(domain: -axis.domain.upperBound ... -axis.domain.lowerBound)
    .chartXAxis {
      AxisMarks(values: xMarks) { value in
        AxisGridLine()
        AxisValueLabel {
          if let date = value.as(Date.self) { Text(xLabel(date)) }
        }
      }
    }
    .chartYAxis { sleepClockAxis(marks: axis.marks, calendar: calendar) }
  }

  /// The day after the last night, the end of its slot.
  private var end: Date {
    calendar.date(byAdding: .day, value: 1, to: period.lastDay) ?? period.lastDay
  }

  /// Every stretch of every night, Awake included, at clock time.
  private var blocks: [SleepBlock] {
    var blocks: [SleepBlock] = []
    for night in period.nights {
      for segment in night.segments {
        blocks.append(
          SleepBlock(
            id: blocks.count, day: night.day, stage: segment.stage,
            start: SleepClock.hours(segment.start, from: night.day, calendar: calendar),
            end: SleepClock.hours(segment.end, from: night.day, calendar: calendar)))
      }
    }
    return blocks
  }

  /// W: every night, by its weekday. M: the start of every week, by its date, as Health has them.
  private var xMarks: [Date] {
    var days: [Date] = []
    var day = period.firstDay
    while day <= period.lastDay {
      if period.range == .week || calendar.component(.weekday, from: day) == calendar.firstWeekday {
        days.append(day)
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return days
  }

  private func xLabel(_ day: Date) -> String {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    return day.formatted(period.range == .week ? style.weekday(.abbreviated) : style.day())
  }
}

/// 6M: a bar per week, from its nights' average bedtime to their average wake, in Sleep's indigo.
struct SleepWeeksChart: View {
  let period: SleepPeriod
  let calendar: Calendar

  var body: some View {
    let weeks = SleepWeek.weeks(period.nights, calendar: calendar)
    let axis = SleepClock.axis(weeks.flatMap { [$0.bedtime, $0.wake] })
    Chart(weeks) { week in
      BarMark(
        x: .value("Week", week.start, unit: .weekOfYear),
        yStart: .value("Bedtime", -week.bedtime), yEnd: .value("Wake", -week.wake),
        width: .ratio(0.6)
      )
      .foregroundStyle(Color.indigo)
    }
    .chartXScale(domain: period.firstDay...end)
    .chartYScale(domain: -axis.domain.upperBound ... -axis.domain.lowerBound)
    .chartXAxis {
      AxisMarks(values: months) { value in
        AxisGridLine()
        AxisValueLabel {
          if let date = value.as(Date.self) {
            Text(
              date.formatted(
                Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
                  .month(.abbreviated)))
          }
        }
      }
    }
    .chartYAxis { sleepClockAxis(marks: axis.marks, calendar: calendar) }
  }

  /// The day after the last night, the end of its week.
  private var end: Date {
    calendar.date(byAdding: .day, value: 1, to: period.lastDay) ?? period.lastDay
  }

  /// The start of every month that starts in the period.
  private var months: [Date] {
    guard
      var month = calendar.dateInterval(of: .month, for: period.firstDay)?.start
    else { return [] }
    var months: [Date] = []
    while month <= period.lastDay {
      if month >= period.firstDay { months.append(month) }
      guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
      month = next
    }
    return months
  }
}

/// The clock-time y-axis, on the trailing side: "10 PM" at the top, "8 AM" at the bottom.
private func sleepClockAxis(marks: [Double], calendar: Calendar) -> some AxisContent {
  AxisMarks(position: .trailing, values: marks.map { -$0 }) { value in
    AxisGridLine()
    AxisValueLabel {
      if let hours = value.as(Double.self) {
        Text(SleepClock.label(-hours, calendar: calendar))
      }
    }
  }
}
