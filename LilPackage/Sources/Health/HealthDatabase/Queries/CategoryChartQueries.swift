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

  /// The category types charted as sessions, whose header is their average length
  /// (`MetricChart.Summary.averageDuration`) rather than a total.
  public static let sessionChartTypes: Set = [handwashingType, toothbrushingType]

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
  /// - **Stand Hours:** hours stood (`categoryValue` 0; 1 is idle), each hour once, however many
  ///   watches recorded it. Days with only idle hours count as days, with none stood: the watch
  ///   was worn, as Activity's Stand ring shows 0 hours for them, so they bring the average down.
  ///   Days without any samples (the watch not worn) don't count.
  /// - **Mindful Minutes:** minutes in sessions, overlapping sessions (from different apps)
  ///   counted once.
  /// - **Handwashing, Toothbrushing:** sessions, overlapping ones (the same session from a
  ///   toothbrush and a watch) counted once, with their average length in the header.
  /// Days split in `calendar`'s time zone.
  public static func categoryChart(
    of typeID: String, range: ChartRange, offset: Int, now: Date, calendar: Calendar,
    _ db: Database
  ) throws -> MetricChart {
    let interval = range.interval(offset: offset, now: now, calendar: calendar)
    let window = interval.start..<interval.end
    let (lower, upper) = (interval.start.unixMilliseconds, interval.end.unixMilliseconds)
    // Sessions that started before the period but run into it count for the part inside it.
    // These are short (an hour at most for a stand hour, a session for the rest), so a day before
    // is enough, and the type and start index bounds the read.
    let earliest = lower - 86_400_000
    let samples =
      try HealthSample
      .where {
        $0.type.eq(typeID) && $0.startDate >= earliest && $0.startDate < upper
          && $0.endDate > lower
      }
      .select { ($0.startDate, $0.endDate, $0.categoryValue) }
      .fetchAll(db)
      .map { (start: Date(unixMilliseconds: $0), end: Date(unixMilliseconds: $1), value: $2) }
    let unit: Calendar.Component = range == .day ? .hour : .day
    var totals: [Date: Double] = [:]
    func bucket(_ date: Date) -> Date { calendar.dateInterval(of: unit, for: date)?.start ?? date }
    var summary: MetricChart.Summary?
    switch typeID {
    case standHourType:
      var stood: Set<Date> = []
      for sample in samples where window.contains(sample.start) {
        // An hour once, whichever watch recorded it.
        let hour = calendar.dateInterval(of: .hour, for: sample.start)?.start ?? sample.start
        if sample.value == 0 { stood.insert(hour) }
        totals[bucket(hour), default: 0] += 0
      }
      for hour in stood { totals[bucket(hour), default: 0] += 1 }
    case mindfulSessionType:
      for session in mergedIntervals(samples.map { $0.start..<max($0.start, $0.end) }) {
        let clamped = session.clamped(to: window)
        // Split at each hour or day it crosses.
        var start = clamped.lowerBound
        while start < clamped.upperBound {
          let end = min(
            calendar.dateInterval(of: unit, for: start)?.end ?? clamped.upperBound,
            clamped.upperBound)
          totals[bucket(start), default: 0] += end.timeIntervalSince(start) / 60
          start = end
        }
      }
    case let id where sessionChartTypes.contains(id):
      // The same session from two sources is one.
      let sessions = mergedIntervals(samples.map { $0.start..<max($0.start, $0.end) })
        .filter { window.contains($0.lowerBound) }
      for session in sessions { totals[bucket(session.lowerBound), default: 0] += 1 }
      if !sessions.isEmpty {
        let seconds = sessions.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
        summary = .averageDuration(seconds / Double(sessions.count))
      }
    default:
      break
    }
    let buckets = totals.sorted { $0.key < $1.key }.map { (start: $0.key, value: $0.value) }
    let points =
      range == .sixMonths || range == .year
      ? averageDays(buckets, by: range, calendar: calendar)
      : buckets.map { ChartPoint(start: $0.start, value: $0.value) }
    if summary == nil, !buckets.isEmpty {
      let total = buckets.reduce(0) { $0 + $1.value }
      summary = range == .day ? .total(total) : .dailyAverage(total / Double(buckets.count))
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
