import Foundation

/// How Browse writes a metric's value and when it's from, the way Health does.
enum MetricFormat {
  /// `value` (in `unit`, as stored) as Health shows it, e.g. ("8,214", "steps") or ("97", "%").
  static func value(_ value: Double, unit: String?, typeID: String) -> (
    number: String, unit: String
  ) {
    let (shown, label) = converted(value, unit: unit, typeID: typeID)
    let digits = abs(shown) >= 100 || label == "%" ? 0 : abs(shown) >= 10 ? 1 : 2
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
    case "count/min": return (value, name == "RespiratoryRate" ? "breaths/min" : "BPM")
    // Stored as a fraction.
    case "%": return (value * 100, "%")
    case "m": return value >= 1000 ? (value / 1000, "km") : (value, "m")
    case "m/s": return (value * 3.6, "km/h")
    case "degC": return (value, "°C")
    case "dBASPL": return (value, "dB")
    case "appleEffortScore": return (value, "")
    case let unit?: return (value, unit)
    case nil: return (value, "")
    }
  }

  /// When the latest data is from: "Today" (or the time, for a moment today), "Yesterday", the
  /// weekday within the last week, then the date.
  static func date(_ date: Date, isDay: Bool, now: Date, calendar: Calendar) -> String {
    let today = calendar.startOfDay(for: now)
    let day = calendar.startOfDay(for: date)
    let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    switch daysAgo {
    case 0: return isDay ? "Today" : date.formatted(date: .omitted, time: .shortened)
    case 1: return "Yesterday"
    case 2..<7: return date.formatted(.dateTime.weekday(.wide))
    default:
      let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
      return sameYear
        ? date.formatted(.dateTime.month(.abbreviated).day())
        : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
  }
}
