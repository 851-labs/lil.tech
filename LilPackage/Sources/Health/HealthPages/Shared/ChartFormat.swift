public import Foundation
public import HealthDatabase

/// How a chart writes its periods: the metric page's, Blood Pressure's.
public enum ChartFormat {
  /// The period shown: "Oct 15, 2025", "Oct 12 – 18, 2025", "Oct 2025", "May – Oct 2025", "2025".
  public static func span(_ interval: DateInterval, range: ChartRange, calendar: Calendar) -> String
  {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    // The last moment inside, so a week doesn't end on the next Sunday.
    let last = interval.end.addingTimeInterval(-1)
    switch range {
    case .day: return interval.start.formatted(style.month(.abbreviated).day().year())
    case .week:
      return (interval.start..<last).formatted(
        Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
    case .month: return interval.start.formatted(style.month(.abbreviated).year())
    case .sixMonths:
      // The year on both ends when the months span two.
      let sameYear =
        calendar.component(.year, from: interval.start) == calendar.component(.year, from: last)
      let first = sameYear ? style.month(.abbreviated) : style.month(.abbreviated).year()
      return
        "\(interval.start.formatted(first)) – \(last.formatted(style.month(.abbreviated).year()))"
    case .year: return interval.start.formatted(style.year())
    }
  }

  /// One bar's period: an hour, a day, a week or a month.
  public static func bucket(_ start: Date, range: ChartRange, calendar: Calendar) -> String {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    switch range {
    case .day: return start.formatted(style.month(.abbreviated).day().hour())
    case .week, .month:
      return start.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
    case .sixMonths: return "Week of \(start.formatted(style.month(.abbreviated).day()))"
    case .year: return start.formatted(style.month(.wide).year())
    }
  }
}
