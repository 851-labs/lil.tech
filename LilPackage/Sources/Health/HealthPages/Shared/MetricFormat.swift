public import Foundation

/// How the Mac's pages and browse write a metric's value and when it's from, the way Health does.
public enum MetricFormat {
  /// `value` (in `unit`, as stored) as Health shows it, e.g. ("8,214", "steps") or ("97", "%").
  public static func value(_ value: Double, unit: String?, typeID: String) -> (
    number: String, unit: String
  ) {
    let (shown, label) = converted(value, unit: unit, typeID: typeID)
    // Whole numbers for counts and the like, as Health shows them (not breaths a minute).
    let whole: Set = [
      "steps", "floors", "pushes", "strokes", "times", "BPM", "RPM", "kcal", "%", "ms", "mmHg",
      "mg/dL", "dB", "W",
    ]
    let digits = whole.contains(label) || abs(shown) >= 100 ? 0 : abs(shown) >= 10 ? 1 : 2
    return (shown.formatted(.number.precision(.fractionLength(0...digits))), label)
  }

  private static func converted(_ value: Double, unit: String?, typeID: String) -> (Double, String)
  {
    let name = typeID.components(separatedBy: "Identifier").last ?? typeID
    switch unit {
    case "count":
      let labels = [
        "StepCount": "steps", "FlightsClimbed": "floors", "PushCount": "pushes",
        "SwimmingStrokeCount": "strokes", "NumberOfTimesFallen": "times",
      ]
      return (value, labels[name] ?? "")
    case "count/min":
      let labels = ["RespiratoryRate": "breaths/min", "CyclingCadence": "RPM"]
      return (value, labels[name] ?? "BPM")
    // Stored as a fraction.
    case "%": return (value * 100, "%")
    // Distances in km, except those Health keeps in metres.
    case "m":
      let metres: Set = ["DistanceSwimming", "SixMinuteWalkTestDistance"]
      return value >= 1000 && !metres.contains(name) ? (value / 1000, "km") : (value, "m")
    // Speeds in km/h, except stair speeds.
    case "m/s": return name.hasPrefix("Stair") ? (value, "m/s") : (value * 3.6, "km/h")
    case "degC": return (value, "°C")
    case "dBASPL": return (value, "dB")
    case "appleEffortScore": return (value, "")
    case let unit?: return (value, unit)
    case nil: return (value, "")
    }
  }

  /// A length of time as Health writes a session's: ("24", "sec"), or ("2", "min") from a
  /// minute.
  public static func duration(_ seconds: TimeInterval) -> (number: String, unit: String) {
    // Rounded first, so 59.7 seconds is a minute.
    guard seconds.rounded() >= 60 else { return (Int(seconds.rounded()).formatted(), "sec") }
    let minutes = seconds / 60
    return (minutes.formatted(.number.precision(.fractionLength(0...1))), "min")
  }

  /// When the latest data is from: "Today" (or the time, for a moment today), "Yesterday", the
  /// weekday within the last week, then the date.
  public static func date(_ date: Date, isDay: Bool, now: Date, calendar: Calendar) -> String {
    let today = calendar.startOfDay(for: now)
    let day = calendar.startOfDay(for: date)
    let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    // In the calendar's time zone, which decided the day.
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    switch daysAgo {
    case 0: return isDay ? "Today" : date.formatted(style.hour().minute())
    case 1: return "Yesterday"
    case 2..<7: return date.formatted(style.weekday(.wide))
    default:
      let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
      return sameYear
        ? date.formatted(style.month(.abbreviated).day())
        : date.formatted(style.month(.abbreviated).day().year())
    }
  }
}
