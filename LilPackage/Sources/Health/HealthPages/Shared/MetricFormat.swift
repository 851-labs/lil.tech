public import Foundation
public import HealthCards

/// How the Mac's pages and browse write a metric's value and when it's from, the way Health does.
public enum MetricFormat {
  /// `value` (in `unit`, as stored) as Health shows it, e.g. ("8,214", "steps") or ("97", "%"),
  /// in the type's display unit for `locale` (`unit(_:typeID:locale:)`).
  public static func value(_ value: Double, unit: String?, typeID: String, locale: Locale) -> (
    number: String, unit: String
  ) {
    let shown = self.unit(unit, typeID: typeID, locale: locale)
    return (shown.format(shown.convert(value)), shown.label)
  }

  /// The unit a type's values are shown in, as Health shows them: one per type, whatever the
  /// value, so a chart's axis, its header and every row agree (851-3105). Walking + Running
  /// Distance is in km even for 400 m, as in Health, and a range never reads "800 m–1.2 km".
  ///
  /// In `locale`'s preferred units (851-3116), as Health picks them: its measurement system
  /// (metric, US or UK) and its temperature unit, both of which the Mac's Language & Region
  /// settings can change. Pass `@Dependency(\.locale)`, so snapshot catalogs fix it. Values are
  /// stored in SI (the catalog's units) whatever the locale.
  public static func unit(_ unit: String?, typeID: String, locale: Locale) -> DisplayUnit {
    var shown = displayUnit(unit, typeID: typeID, locale: locale)
    // Numbers are written in it too.
    shown.locale = locale
    return shown
  }

  private static func displayUnit(_ unit: String?, typeID: String, locale: Locale) -> DisplayUnit {
    let name = typeID.components(separatedBy: "Identifier").last ?? typeID
    let system = UnitSystem(locale)
    switch unit {
    case "count": return DisplayUnit(countLabels[name] ?? "")
    case "count/min": return DisplayUnit(rateLabels[name] ?? "BPM")
    // Stored as a fraction.
    case "%": return DisplayUnit("%", scale: 100)
    case "m": return length(name, system)
    // Speeds in km/h or mph, except stair speeds, in m/s or ft/s.
    case "m/s":
      if name.hasPrefix("Stair") {
        return system == .metric ? DisplayUnit("m/s") : DisplayUnit("ft/s", scale: 1 / foot)
      }
      return system == .metric
        ? DisplayUnit("km/h", scale: 3.6) : DisplayUnit("mph", scale: 3_600 / mile)
    // Running's vertical oscillation.
    case "cm":
      return system == .metric ? DisplayUnit("cm") : DisplayUnit("in", scale: 0.01 / inch)
    case "kg":
      switch system {
      case .metric: return DisplayUnit("kg")
      case .us: return DisplayUnit("lb", scale: 1 / pound)
      // Stones and pounds, as the UK weighs people, plotted in pounds.
      case .uk: return DisplayUnit("", scale: 1 / pound, compound: .stonesAndPounds)
      }
    case "degC":
      return prefersFahrenheit(locale)
        ? DisplayUnit("°F", scale: 1.8, offset: 32) : DisplayUnit("°C")
    // Water. The UK's fluid ounce isn't the US's, and it drinks in millilitres.
    case "mL":
      return system == .us ? DisplayUnit("fl oz", scale: 1 / usFluidOunce) : DisplayUnit("mL")
    case "dBASPL": return DisplayUnit("dB")
    case "appleEffortScore": return DisplayUnit("")
    // Cardio Fitness, as Health labels it.
    case "ml/(kg*min)": return DisplayUnit("VO₂ max")
    case let unit?: return DisplayUnit(unit)
    case nil: return DisplayUnit("")
    }
  }

  /// A type stored in metres. Distances covered are in km or mi whatever their length, except
  /// swimming's, in metres, or yards in the US. Height, waist and a step are in cm, as Health
  /// shows them, or feet and inches and inches; longer lengths (a six-minute walk, a stride, a
  /// dive) in metres, or yards and feet.
  private static func length(_ name: String, _ system: UnitSystem) -> DisplayUnit {
    let metric = system == .metric
    switch name {
    case "DistanceSwimming":
      return system == .us ? DisplayUnit("yd", scale: 1 / yard) : DisplayUnit("m")
    case _ where name.hasPrefix("Distance"):
      return metric ? DisplayUnit("km", scale: 0.001) : DisplayUnit("mi", scale: 1 / mile)
    // Plotted in inches, so an axis's ticks fall on whole ones: 5′ 8″, 5′ 10″.
    case "Height":
      return metric
        ? DisplayUnit("cm", scale: 100) : DisplayUnit("", scale: 1 / inch, compound: .feetAndInches)
    case "WaistCircumference", "WalkingStepLength":
      return metric ? DisplayUnit("cm", scale: 100) : DisplayUnit("in", scale: 1 / inch)
    case "SixMinuteWalkTestDistance":
      return metric ? DisplayUnit("m") : DisplayUnit("yd", scale: 1 / yard)
    default:
      return metric ? DisplayUnit("m") : DisplayUnit("ft", scale: 1 / foot)
    }
  }

  /// A swim's distance in a pool measured in yards or metres, which Health shows in the pool's
  /// unit whatever the locale (a workout's lap length, 851-3176), with `locale`'s numbers.
  public static func swimmingUnit(yards: Bool, locale: Locale) -> DisplayUnit {
    var shown = yards ? DisplayUnit("yd", scale: 1 / yard) : DisplayUnit("m")
    shown.locale = locale
    return shown
  }

  // Exact, by definition.
  private static let inch = 0.0254
  private static let foot = 0.3048
  private static let yard = 0.9144
  private static let mile = 1_609.344
  private static let pound = 0.453_592_37
  private static let usFluidOunce = 29.573_529_562_5

  /// Which of Foundation's measurement systems `locale` uses: the US's, the UK's (miles and
  /// stones, with metric volumes), or the metric system, which any other is taken as.
  enum UnitSystem {
    case metric, us, uk

    init(_ locale: Locale) {
      switch locale.measurementSystem {
      case .us: self = .us
      case .uk: self = .uk
      default: self = .metric
      }
    }
  }

  /// Whether `locale` shows temperatures in °F: the region's, or the one chosen in the Mac's
  /// Language & Region settings. Foundation has no property for it, so this asks the formatter
  /// Apple's apps use for a temperature in the locale's preferred unit (a weather's) to write
  /// 100 °C, and reads its number, in whichever digits, rather than its symbol, which some
  /// languages write in their own script (Arabic's °ف). About 5 µs.
  static func prefersFahrenheit(_ locale: Locale) -> Bool {
    let formatted = Measurement(value: 100, unit: UnitTemperature.celsius)
      .formatted(.measurement(width: .abbreviated, usage: .weather).locale(locale))
    return formatted.compactMap(\.wholeNumberValue) == [2, 1, 2]
  }

  private static let countLabels = [
    "StepCount": "steps", "FlightsClimbed": "floors", "PushCount": "pushes",
    "SwimmingStrokeCount": "strokes", "NumberOfTimesFallen": "times",
  ]
  private static let rateLabels = ["RespiratoryRate": "breaths/min", "CyclingCadence": "RPM"]

  /// What a type's values are shown in (`MetricFormat.unit(_:typeID:locale:)`): the label after
  /// the number, and the conversion from the stored unit. Charts plot `convert`ed values, so their
  /// axes read in the same unit as the header, with round ticks in it (851-3105).
  public struct DisplayUnit: Equatable, Sendable {
    /// As Health writes it after the number: "km/h", "%", or "" for none (and for a compound
    /// unit, which `format` writes in full).
    public let label: String
    /// What a stored value is multiplied by.
    public let scale: Double
    /// What's added after scaling: 32 for °F.
    public let offset: Double
    /// A value written in two units, plotted in the smaller one.
    public let compound: Compound?
    /// Whose numbers it writes: the one it was picked for.
    public fileprivate(set) var locale = Locale.autoupdatingCurrent

    /// Two units a value is written in: 5′ 11″, 11 st 4 lb.
    public enum Compound: Equatable, Sendable {
      /// Plotted in inches.
      case feetAndInches
      /// Plotted in pounds.
      case stonesAndPounds
    }

    init(_ label: String, scale: Double = 1, offset: Double = 0, compound: Compound? = nil) {
      self.label = label
      self.scale = scale
      self.offset = offset
      self.compound = compound
    }

    /// A stored value in this unit.
    public func convert(_ stored: Double) -> Double { stored * scale + offset }

    /// A value already in this unit, as Health writes it: whole numbers for counts and the like
    /// (not breaths a minute), otherwise fewer decimals the larger it is. A distance under 1 km
    /// or 1 mi gets a third, so a 4 m sample isn't "0 km". Pounds and °F keep one from 100, so a
    /// weight's change and a fever show.
    public func format(_ shown: Double) -> String {
      // A compound's whole units can't be counted.
      guard shown.isFinite else { return shown.formatted(.number.locale(locale)) }
      switch compound {
      case .feetAndInches:
        let inches = Int(shown.rounded())
        let (feet, rest) = inches.quotientAndRemainder(dividingBy: 12)
        let number = { (value: Int) in value.formatted(.number.locale(locale)) }
        return rest == 0 ? "\(number(feet))′" : "\(number(feet))′ \(number(rest))″"
      case .stonesAndPounds:
        // In tenths of a pound, so 4.96 lb isn't 5 lb short of the next stone.
        let tenths = Int((shown * 10).rounded())
        let (stones, rest) = tenths.quotientAndRemainder(dividingBy: 140)
        let pounds = (Double(rest) / 10).formatted(
          .number.precision(.fractionLength(0...1)).locale(locale))
        let whole = stones.formatted(.number.locale(locale))
        return rest == 0 ? "\(whole) st" : "\(whole) st \(pounds) lb"
      case nil:
        break
      }
      let size = abs(shown)
      let digits =
        Self.whole.contains(label) || size >= 100 && !Self.tenthsFrom100.contains(label)
        ? 0 : size >= 10 ? 1 : size < 1 && (label == "km" || label == "mi") ? 3 : 2
      return shown.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
    }

    private static let whole: Set = [
      "steps", "floors", "pushes", "strokes", "times", "BPM", "RPM", "kcal", "%", "ms", "mmHg",
      "mg/dL", "dB", "W",
    ]
    private static let tenthsFrom100: Set = ["lb", "°F"]

    /// The distance between an axis's ticks over `span` (in this unit) for a compound unit, so
    /// each falls on a value its label writes exactly, and no two read the same: whole inches,
    /// feet or yards, whole pounds or stones. Nil for other units, whose ticks Charts picks.
    public func compoundTickStride(over span: Double) -> Double? {
      let strides: [Double] =
        switch compound {
        case .feetAndInches: [1, 2, 3, 6, 12, 24, 36, 60, 120]
        case .stonesAndPounds: [1, 2, 7, 14, 28, 70, 140, 280]
        case nil: []
        }
      guard let largest = strides.last else { return nil }
      // At most 5 ticks, as Charts' own axes have.
      return strides.first { span / $0 <= 5 } ?? largest
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

extension MetricFormat {
  /// The unit a card's values are shown in (docs/decisions/cards.md, Display): its `display.unit`
  /// if it pins one, else the locale's for its lead's type, as Metric Detail shows the type
  /// (`unit(_:typeID:locale:)`). A count of readings is a plain number in any locale.
  public static func unit(of spec: CardSpec, locale: Locale) -> DisplayUnit {
    var shown: DisplayUnit
    switch spec.valueUnit {
    case .readings?:
      shown = DisplayUnit("readings")
    case .catalog(let catalogUnit)?:
      if let pinned = spec.display.unit,
        let conversion = CardDisplayUnit.conversion(from: catalogUnit, to: pinned)
      {
        shown =
          pinned == "st"
          // Stones and pounds, as the UK weighs people, plotted in pounds, as its locale's are.
          ? DisplayUnit("", scale: conversion.scale * 14, compound: .stonesAndPounds)
          : DisplayUnit(
            cardUnitLabels[pinned] ?? pinned, scale: conversion.scale, offset: conversion.offset)
      } else {
        return unit(catalogUnit, typeID: spec.leadType ?? "", locale: locale)
      }
    case nil:
      shown = DisplayUnit("")
    }
    shown.locale = locale
    return shown
  }

  /// How Health writes the units a card may pin, after the number.
  private static let cardUnitLabels = [
    "degC": "°C", "degF": "°F", "km/hr": "km/h", "mi/hr": "mph", "fl_oz_us": "fl oz",
  ]
}
