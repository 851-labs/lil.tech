public import Foundation

/// How the Mac's pages and browse write a metric's value and when it's from, the way Health does.
public enum MetricFormat {
  /// `value` (in `unit`, as stored) as Health shows it, e.g. ("8,214", "steps") or ("97", "%"),
  /// in the type's display unit (`unit(_:typeID:)`).
  public static func value(_ value: Double, unit: String?, typeID: String) -> (
    number: String, unit: String
  ) {
    let shown = self.unit(unit, typeID: typeID)
    return (shown.format(shown.convert(value)), shown.label)
  }

  /// The unit a type's values are shown in, as Health shows them: one per type, whatever the
  /// value, so a chart's axis, its header and every row agree (851-3105). Walking + Running
  /// Distance is in km even for 400 m, as in Health, and a range never reads "800 m–1.2 km".
  public static func unit(_ unit: String?, typeID: String) -> DisplayUnit {
    let name = typeID.components(separatedBy: "Identifier").last ?? typeID
    switch unit {
    case "count":
      let labels = [
        "StepCount": "steps", "FlightsClimbed": "floors", "PushCount": "pushes",
        "SwimmingStrokeCount": "strokes", "NumberOfTimesFallen": "times",
      ]
      return DisplayUnit(labels[name] ?? "")
    case "count/min":
      let labels = ["RespiratoryRate": "breaths/min", "CyclingCadence": "RPM"]
      return DisplayUnit(labels[name] ?? "BPM")
    // Stored as a fraction.
    case "%": return DisplayUnit("%", scale: 100)
    // Distances covered in km, except swimming, which Health keeps in metres. Lengths (height,
    // a step, a six-minute walk) stay in metres.
    case "m":
      return name.hasPrefix("Distance") && name != "DistanceSwimming"
        ? DisplayUnit("km", scale: 0.001) : DisplayUnit("m")
    // Speeds in km/h, except stair speeds.
    case "m/s":
      return name.hasPrefix("Stair") ? DisplayUnit("m/s") : DisplayUnit("km/h", scale: 3.6)
    case "degC": return DisplayUnit("°C")
    case "dBASPL": return DisplayUnit("dB")
    case "appleEffortScore": return DisplayUnit("")
    // Cardio Fitness, as Health labels it.
    case "ml/(kg*min)": return DisplayUnit("VO₂ max")
    case let unit?: return DisplayUnit(unit)
    case nil: return DisplayUnit("")
    }
  }

  /// What a type's values are shown in (`MetricFormat.unit(_:typeID:)`): the label after the
  /// number, and the scale from the stored unit. Charts plot `convert`ed values, so their axes
  /// read in the same unit as the header, with round ticks in it (851-3105).
  public struct DisplayUnit: Equatable, Sendable {
    /// As Health writes it after the number: "km/h", "%", or "" for none.
    public let label: String
    /// What a stored value is multiplied by.
    public let scale: Double

    init(_ label: String, scale: Double = 1) {
      self.label = label
      self.scale = scale
    }

    /// A stored value in this unit.
    public func convert(_ stored: Double) -> Double { stored * scale }

    /// A value already in this unit, as Health writes it: whole numbers for counts and the like
    /// (not breaths a minute), otherwise fewer decimals the larger it is.
    public func format(_ shown: Double) -> String {
      let whole: Set = [
        "steps", "floors", "pushes", "strokes", "times", "BPM", "RPM", "kcal", "%", "ms", "mmHg",
        "mg/dL", "dB", "W",
      ]
      let digits = whole.contains(label) || abs(shown) >= 100 ? 0 : abs(shown) >= 10 ? 1 : 2
      return shown.formatted(.number.precision(.fractionLength(0...digits)))
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
