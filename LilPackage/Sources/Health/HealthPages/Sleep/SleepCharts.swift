import Charts
import Foundation
import HealthDatabase
import SwiftUI

// Sleep's charts for W, M and 6M, as Health draws them (851-3098): each night a column at the
// clock times it ran, bedtime at the top, stacked by stage; 6M a bar a week from its average
// bedtime to its average wake. The y-axis is clock time, on the trailing side. Each night is on
// its own clock, its recorded zone's (`SleepNight.clock(calendar:)`, 851-4178), as Health draws a
// night slept in Tokyo at Tokyo's times; its slot is still its day's on the page's calendar.

/// Where sleep goes on a chart's clock-time axis, at the times `SleepNight.clockHours` gives.
enum SleepClock {
  /// The middle `ratio` of `day`'s slot on the x-axis, by the page's calendar rather than the
  /// one Charts would bin with.
  static func slot(_ day: Date, ratio: Double, unit: Calendar.Component, calendar: Calendar)
    -> (start: Date, end: Date)
  {
    let interval =
      calendar.dateInterval(of: unit, for: day) ?? DateInterval(start: day, duration: 86_400)
    let inset = interval.duration * (1 - ratio) / 2
    return (interval.start.addingTimeInterval(inset), interval.end.addingTimeInterval(-inset))
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

  /// Every 2 hours on `calendar`'s clock from the hour `start` is in, those from `start` through
  /// `end`, as Charts' `.stride(by: .hour, count: 2)` marks them: where D's chart and the heart
  /// rate highlight mark a night's hours. On the night's clock (851-4178), since Charts' stride
  /// and `.dateTime.hour()` read the process's time zone, so a night in a half-hour zone is
  /// marked on its own hours.
  /// Across a daylight saving change, they stay 2 clock hours apart: the clock's hours with
  /// the first's parity, a repeated hour marked once and a skipped one passed over.
  static func hourMarks(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
    guard var hour = calendar.dateInterval(of: .hour, for: start)?.start else { return [] }
    let parity = calendar.component(.hour, from: hour) % 2
    var marks: [Date] = []
    var last: Int?
    while hour <= end {
      let clock = calendar.component(.hour, from: hour)
      if clock % 2 == parity, clock != last {
        if hour >= start { marks.append(hour) }
        last = clock
      }
      hour.addTimeInterval(3600)
    }
    return marks
  }

  /// An hour mark's label, "10 PM", on `calendar`'s clock and in its locale.
  static func hourLabel(_ date: Date, calendar: Calendar) -> String {
    date.formatted(
      Date.FormatStyle(
        date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
        timeZone: calendar.timeZone
      ).hour())
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

/// A night's stretch of one stage, at clock time, in its night's slot.
private struct SleepBlock: Identifiable {
  let id: Int
  let slot: (start: Date, end: Date)
  let stage: SleepStage
  /// Hours from the start of `day` (`SleepClock`).
  let start: Double
  let end: Double
}

/// A week's average sleep, at clock time, for 6M.
struct SleepWeek: Equatable, Identifiable, Sendable {
  var id: Date { start }
  /// The start of the week.
  let start: Date
  /// The average time the week's nights fell asleep, and woke, in hours from their days' starts,
  /// each night's on its own clock.
  let bedtime: Double
  let wake: Double

  /// Each week with a night, oldest first: its nights' average time asleep, from the first
  /// stretch of sleep to the last, as Health's 6M bars.
  static func weeks(_ nights: [SleepNight], calendar: Calendar) -> [SleepWeek] {
    let spans = nights.compactMap { night -> (week: Date, start: Double, end: Double)? in
      let asleep = night.segments.filter(\.stage.isAsleep)
      guard let start = asleep.map(\.start).min(), let end = asleep.map(\.end).max(),
        let place = night.clockPlacer(calendar: calendar),
        let week = calendar.dateInterval(of: .weekOfYear, for: night.day)?.start
      else { return nil }
      return (week, place(start), place(end))
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
      // A rectangle rather than a bar: bars take one of x and y as a single value, binned by
      // Charts' own calendar.
      RectangleMark(
        xStart: .value("Night", block.slot.start), xEnd: .value("Night", block.slot.end),
        yStart: .value("Start", -block.start), yEnd: .value("End", -block.end)
      )
      .foregroundStyle(SleepFormat.color(block.stage))
      // Square, so a night's stretches join into one column.
      .cornerRadius(0)
    }
    .sleepChartScales(period, axis: axis, calendar: calendar)
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

  /// Every stretch of every night, Awake included, at clock time, on its night's own clock.
  private var blocks: [SleepBlock] {
    var blocks: [SleepBlock] = []
    let ratio = period.range == .week ? 0.3 : 0.6
    for night in period.nights {
      guard let place = night.clockPlacer(calendar: calendar) else { continue }
      let slot = SleepClock.slot(night.day, ratio: ratio, unit: .day, calendar: calendar)
      for segment in night.segments {
        blocks.append(
          SleepBlock(
            id: blocks.count, slot: slot, stage: segment.stage, start: place(segment.start),
            end: place(segment.end)))
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
    // Averaged once, as the period loads (`SleepRequest`).
    let weeks = period.weeks
    let axis = SleepClock.axis(weeks.flatMap { [$0.bedtime, $0.wake] })
    Chart(weeks) { week in
      let slot = SleepClock.slot(week.start, ratio: 0.6, unit: .weekOfYear, calendar: calendar)
      RectangleMark(
        xStart: .value("Week", slot.start), xEnd: .value("Week", slot.end),
        yStart: .value("Bedtime", -week.bedtime), yEnd: .value("Wake", -week.wake)
      )
      .foregroundStyle(Color.indigo)
      .cornerRadius(3)
    }
    .sleepChartScales(period, axis: axis, calendar: calendar)
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

extension View {
  /// A sleep chart's scales: the period's nights across, through the end of its last day, and
  /// `axis`'s clock times down, negated so later is lower: bedtime at the top, as in Health.
  fileprivate func sleepChartScales(
    _ period: SleepPeriod, axis: (domain: ClosedRange<Double>, marks: [Double]),
    calendar: Calendar
  ) -> some View {
    let end = calendar.date(byAdding: .day, value: 1, to: period.lastDay) ?? period.lastDay
    return
      self
      .chartXScale(domain: period.firstDay...end)
      .chartYScale(domain: -axis.domain.upperBound ... -axis.domain.lowerBound)
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

/// A night's stages over time, a row each, as Health draws D: the page's chart, and last night's
/// in the highlights (851-3112), with thinner bars.
struct SleepStagesChart: View {
  let segments: [SleepSegment]
  let rows: [SleepStage]
  /// Whose hours the x-axis marks: the night's own clock (`SleepNight.clock(calendar:)`,
  /// 851-4178), so a night slept in Tokyo reads Tokyo's times.
  let calendar: Calendar
  /// Each bar's height: a share of its row, or fixed.
  var barHeight: MarkDimension = .ratio(0.7)
  /// The times it shows, its x-axis's domain, without segments: the empty night's.
  var span: ClosedRange<Date>?

  var body: some View {
    if let span {
      chart.chartXScale(domain: span)
    } else {
      chart
    }
  }

  private var chart: some View {
    Chart(Array(segments.enumerated()), id: \.offset) { _, segment in
      BarMark(
        xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
        y: .value("Stage", SleepFormat.name(segment.stage)), height: barHeight
      )
      .foregroundStyle(SleepFormat.color(segment.stage))
      .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    .chartYScale(domain: rows.map(SleepFormat.name))
    // The stages' names, which Charts drew white in light mode (851-2869), as did the
    // secondary styles (`.secondary`, `Color.secondary`) set on them. The primary color, faded,
    // follows the appearance.
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let name = value.as(String.self) {
            Text(name)
              .foregroundStyle(Color.primary.opacity(0.6))
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: hourMarks) { value in
        AxisGridLine()
        AxisValueLabel {
          if let date = value.as(Date.self) {
            Text(SleepClock.hourLabel(date, calendar: calendar))
          }
        }
      }
    }
    // On the night's clock, so Charts' own dates (VoiceOver's, the audio graph's) read as the
    // labels do.
    .environment(\.calendar, calendar)
    .environment(\.timeZone, calendar.timeZone)
  }

  /// Every 2 hours on the night's clock, over its segments or `span`.
  private var hourMarks: [Date] {
    guard
      let span = span
        ?? segments.map(\.start).min().flatMap({ start in
          segments.map(\.end).max().map { start...max(start, $0) }
        })
    else { return [] }
    return SleepClock.hourMarks(from: span.lowerBound, to: span.upperBound, calendar: calendar)
  }
}
