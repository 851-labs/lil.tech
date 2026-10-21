public import Foundation
import HealthCatalog
public import SQLiteData

/// Charts of category types that Health charts like metrics (851-2831): stand hours, mindful
/// minutes, and handwashing and toothbrushing sessions.
extension HealthDatabase {
  public static let standHourType = "HKCategoryTypeIdentifierAppleStandHour"
  public static let mindfulSessionType = "HKCategoryTypeIdentifierMindfulSession"
  public static let handwashingType = "HKCategoryTypeIdentifierHandwashingEvent"
  public static let toothbrushingType = "HKCategoryTypeIdentifierToothbrushingEvent"

  /// The category types charted on the metric page.
  public static let categoryChartTypes: Set = [
    standHourType, mindfulSessionType, handwashingType, toothbrushingType,
  ]

  /// The unit a category chart's values are in, as `MetricFormat` writes it.
  public static func categoryChartUnit(_ typeID: String) -> String? {
    switch typeID {
    case standHourType: "hr"
    case mindfulSessionType: "min"
    case handwashingType, toothbrushingType: "times"
    default: nil
    }
  }

  /// A category type over the period `offset` periods back, as a cumulative type's chart is: a
  /// total per hour (a day) or per day, and for six months or a year the average day of each week
  /// or month, with the day's total or the average day in the header. What's counted depends on
  /// the type:
  /// - **Stand Hours:** hours stood (`categoryValue` 0; 1 is idle), one per hour-long sample.
  /// - **Mindful Minutes:** minutes in sessions, overlapping sessions (from different apps)
  ///   counted once.
  /// - **Handwashing, Toothbrushing:** sessions, with their average length in the header.
  /// Days split in `calendar`'s time zone.
  public static func categoryChart(
    of typeID: String, range: ChartRange, offset: Int, now: Date, calendar: Calendar,
    _ db: Database
  ) throws -> MetricChart {
    let interval = range.interval(offset: offset, now: now, calendar: calendar)
    let (lower, upper) = (interval.start.unixMilliseconds, interval.end.unixMilliseconds)
    // Sessions that started before the period but run into it count for the part inside it.
    let samples =
      try HealthSample
      .where { $0.type.eq(typeID) && $0.endDate > lower && $0.startDate < upper }
      .order(by: \.startDate)
      .fetchAll(db)
    let byDay = range != .day
    let unit: Calendar.Component = byDay ? .day : .hour
    var totals: [Date: Double] = [:]
    func add(_ amount: Double, at date: Date) {
      let start = calendar.dateInterval(of: unit, for: date)?.start ?? date
      totals[start, default: 0] += amount
    }
    switch typeID {
    case standHourType:
      for sample in samples where sample.categoryValue == 0 && sample.startDate >= lower {
        add(1, at: sample.start)
      }
    case mindfulSessionType:
      let window = interval.start..<interval.end
      for session in mergedIntervals(samples.map { $0.start..<max($0.start, $0.end) }) {
        guard let clamped = session.clampedIfOverlapping(window) else { continue }
        // Split at each hour or day it crosses.
        var start = clamped.lowerBound
        while start < clamped.upperBound {
          let bucketEnd = calendar.dateInterval(of: unit, for: start)?.end ?? clamped.upperBound
          let end = min(bucketEnd, clamped.upperBound)
          add(end.timeIntervalSince(start) / 60, at: start)
          start = end
        }
      }
    default:
      for sample in samples where sample.startDate >= lower { add(1, at: sample.start) }
    }
    let days = totals.sorted { $0.key < $1.key }
    var points = days.map { ChartPoint(start: $0.key, value: $0.value) }
    if range == .sixMonths || range == .year {
      // The average day of each week or month, among days with any.
      var groups: [(start: Date, sum: Double, days: Int)] = []
      for (day, value) in days {
        let start = calendar.dateInterval(of: range.bucket.component, for: day)?.start ?? day
        if groups.last?.start == start {
          groups[groups.count - 1].sum += value
          groups[groups.count - 1].days += 1
        } else {
          groups.append((start, value, 1))
        }
      }
      points = groups.map { ChartPoint(start: $0.start, value: $0.sum / Double($0.days)) }
    }
    let total = days.reduce(0) { $0 + $1.value }
    var summary: MetricChart.Summary?
    switch typeID {
    case handwashingType, toothbrushingType:
      let inPeriod = samples.filter { $0.startDate >= lower }
      if !inPeriod.isEmpty {
        let seconds = inPeriod.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        summary = .averageDuration(seconds / Double(inPeriod.count))
      }
    default:
      if !days.isEmpty {
        // A day's hours are one day.
        let dayCount = byDay ? days.count : 1
        summary = range == .day ? .total(total) : .dailyAverage(total / Double(dayCount))
      }
    }
    return MetricChart(interval: interval, points: points, summary: summary)
  }

  /// `intervals` with overlapping ones joined, in order: the time covered by any of them.
  static func mergedIntervals(_ intervals: [Range<Date>]) -> [Range<Date>] {
    var merged: [Range<Date>] = []
    for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = merged.last, interval.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, interval.upperBound)
      } else {
        merged.append(interval)
      }
    }
    return merged
  }
}

extension Range where Bound == Date {
  /// The part inside `other`, if any.
  fileprivate func clampedIfOverlapping(_ other: Range<Date>) -> Range<Date>? {
    let clamped = clamped(to: other)
    return clamped.isEmpty ? nil : clamped
  }
}
