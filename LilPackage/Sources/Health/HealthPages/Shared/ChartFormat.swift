public import Foundation
public import HealthDatabase
import HealthUI

/// How a chart writes its periods: the metric page's, Blood Pressure's.
public enum ChartFormat {
  /// The period shown: "Oct 15, 2025", "Oct 12 – 18, 2025", "Oct 2025", "May – Oct 2025", "2025".
  public static func span(_ interval: DateInterval, range: ChartRange, calendar: Calendar) -> String
  {
    PeriodFormat.span(interval, range: range.card, calendar: calendar)
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

extension ChartFormat {
  /// What VoiceOver reads for an empty period's chart: "No data for Aug 11 – 17, 2024".
  public static func noData(_ period: String) -> String {
    PeriodFormat.noData(period)
  }

  /// What VoiceOver reads for a symptom's period whose entries say it wasn't there: "Not present
  /// in Aug 11 – 17, 2024".
  public static func notPresent(_ period: String) -> String {
    "Not present in \(period)"
  }
}
