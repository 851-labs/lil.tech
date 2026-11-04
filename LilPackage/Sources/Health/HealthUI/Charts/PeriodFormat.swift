public import Foundation
public import HealthCards

/// How a chart writes its period, on both apps (851-3212): Metric Detail's and a card's page's.
public enum PeriodFormat {
  /// The period shown: "Oct 15, 2025", "Oct 12 – 18, 2025", "Oct 2025", "May – Oct 2025", "2025".
  public static func span(_ interval: DateInterval, range: CardRange, calendar: Calendar) -> String
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

  /// What VoiceOver reads for an empty period's chart: "No data for Aug 11 – 17, 2024".
  public static func noData(_ period: String) -> String {
    "No data for \(period)"
  }
}
