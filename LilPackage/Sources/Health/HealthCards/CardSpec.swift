import Foundation
public import HealthCatalog

/// What a card charts and how it looks: the card spec, version 1 (docs/decisions/cards.md, The card
/// spec, v1). A value is always canonical, every default filled in: make one from input with
/// `init(input:)`, which validates it, and write it with `json`.
public struct CardSpec: Hashable, Sendable {
  public var version: Int
  public var display: Display
  public var series: [Series]
  public var formulas: [Formula]
  public var bucket: Bucket
  public var range: CardRange
  public var chart: Chart

  public init(
    version: Int = HealthCards.specVersion, display: Display, series: [Series],
    formulas: [Formula] = [], bucket: Bucket = .auto, range: CardRange, chart: Chart
  ) {
    self.version = version
    self.display = display
    self.series = series
    self.formulas = formulas
    self.bucket = bucket
    self.range = range
    self.chart = chart
  }

  public struct Display: Hashable, Sendable {
    /// What Summary and the page title show, trimmed.
    public var name: String
    /// One of `HealthCards.cardSymbols`.
    public var symbol: String
    public var color: CardColor
    /// One of `CardDisplayUnit.all`, or `nil` for the locale's unit.
    public var unit: String?

    public init(name: String, symbol: String, color: CardColor, unit: String? = nil) {
      self.name = name
      self.symbol = symbol
      self.color = color
      self.unit = unit
    }
  }

  /// One quantity type, aggregated per bucket.
  public struct Series: Hashable, Sendable {
    public var id: String
    /// A HealthKit identifier: a quantity type the catalog reads with standard authorization.
    public var type: String
    public var aggregation: Aggregation
    public var window: Window?
    public var filter: Filter?
    public var label: String?
    public var hidden: Bool

    public init(
      id: String, type: String, aggregation: Aggregation, window: Window? = nil,
      filter: Filter? = nil, label: String? = nil, hidden: Bool = false
    ) {
      self.id = id
      self.type = type
      self.aggregation = aggregation
      self.window = window
      self.filter = filter
      self.label = label
      self.hidden = hidden
    }

    /// The catalog's type. Always there for a validated spec.
    public var dataType: HealthDataType? { HealthCatalog.type(id: type) }

    /// The unit of the series' values: its type's catalog unit, or `count` for a count of
    /// readings, whatever the type.
    public var valueUnit: CardValueUnit {
      aggregation == .count ? .readings : .catalog(dataType?.unit ?? "")
    }
  }

  public enum Aggregation: String, CaseIterable, Hashable, Sendable {
    /// Cumulative types' only aggregation: Health's de-duplicated totals.
    case sum
    /// The weighted average of the bucket's readings.
    case avg
    case min
    case max
    /// The reading that started first. Ties go to the earlier end, then the smaller sample ID.
    case first
    /// The reading that started last. Ties go to the later end, then the greater sample ID.
    case latest
    /// How many readings: its unit is `count`, whatever the type.
    case count

    /// What a type takes: `sum` for cumulative types, the others for the rest.
    public static func allowed(for aggregation: HealthDataType.Aggregation) -> [Self] {
      aggregation.isCumulative ? [.sum] : [.avg, .min, .max, .first, .latest, .count]
    }

    /// The default for a type: `sum` for cumulative types, else `avg`.
    public static func defaultValue(for aggregation: HealthDataType.Aggregation) -> Self {
      aggregation.isCumulative ? .sum : .avg
    }
  }

  /// Stretches of time a series' readings must start in.
  public enum Window: Hashable, Sendable {
    /// Each night's stretches asleep.
    case asleep
    /// `[F − minutes, F)`, where `F` is when the night's sleep started.
    case beforeSleep(minutes: Int)
    /// `[W, W + minutes)`, where `W` is when the night's sleep ended.
    case afterWaking(minutes: Int)
    /// Each workout, of the activities given (`HKWorkoutActivityType` raw values), or of every
    /// activity when `nil`.
    case workout(activities: [Int]?)
    /// Readings whose start is within hours of the local clock, every day.
    case timeOfDay(CardTimeOfDay)

    public enum Kind: String, CaseIterable, Hashable, Sendable {
      case asleep, beforeSleep, afterWaking, workout, timeOfDay

      /// Whether it's made of nights' stretches.
      public var isSleep: Bool { self == .asleep || self == .beforeSleep || self == .afterWaking }
    }

    public var kind: Kind {
      switch self {
      case .asleep: .asleep
      case .beforeSleep: .beforeSleep
      case .afterWaking: .afterWaking
      case .workout: .workout
      case .timeOfDay: .timeOfDay
      }
    }

    /// Whether the window is made of nights' stretches, so its readings belong to nights.
    public var isSleep: Bool { kind.isSleep }
  }

  /// Which readings count: those that match every list given.
  public struct Filter: Hashable, Sendable {
    /// Source bundle IDs, matched exactly.
    public var sources: [String]?
    /// `HKDevice` models, matched exactly.
    public var deviceModels: [String]?

    public init(sources: [String]? = nil, deviceModels: [String]? = nil) {
      self.sources = sources
      self.deviceModels = deviceModels
    }
  }

  /// A line derived from series.
  public struct Formula: Hashable, Sendable {
    public var id: String
    public var operation: Operation
    public var label: String?
    public var hidden: Bool

    public init(id: String, operation: Operation, label: String? = nil, hidden: Bool = false) {
      self.id = id
      self.operation = operation
      self.label = label
      self.hidden = hidden
    }

    public enum Kind: String, CaseIterable, Hashable, Sendable {
      case movingAverage, difference
    }

    public enum Operation: Hashable, Sendable {
      /// The average of the series' values over each bucket and the `points − 1` before it.
      case movingAverage(of: String, points: Int)
      /// `minuend` minus `subtrahend`, where both have a value.
      case difference(of: String, minus: String)

      public var kind: Kind {
        switch self {
        case .movingAverage: .movingAverage
        case .difference: .difference
        }
      }

      /// The IDs of the series it's computed from.
      public var seriesIDs: [String] {
        switch self {
        case .movingAverage(let of, _): [of]
        case .difference(let a, let b): [a, b]
        }
      }
    }
  }

  /// What each point covers.
  public enum Bucket: String, CaseIterable, Hashable, Sendable {
    /// The range's grain, as Metric Detail: an hour (D), a day (W, M), a week (6M), a month (Y).
    case auto
    case hour
    case day
    /// A night, at the day it ends on.
    case night
    case week
    case month

    /// The ranges a card of this bucket may open on and offer.
    public var ranges: [CardRange] {
      switch self {
      case .auto, .night: CardRange.allCases
      case .hour: [.day, .week]
      case .day: [.week, .month, .sixMonths, .year]
      case .week: [.month, .sixMonths, .year]
      case .month: [.sixMonths, .year]
      }
    }

    /// The range a card opens on by default: W, or the bucket's first when it doesn't have W.
    public var defaultRange: CardRange {
      ranges.contains(.week) ? .week : ranges[0]
    }
  }

  public struct Chart: Hashable, Sendable {
    public var style: HealthDataType.ChartStyle
    public var goal: Goal?

    public init(style: HealthDataType.ChartStyle, goal: Goal? = nil) {
      self.style = style
      self.goal = goal
    }
  }

  /// A horizontal rule, in the lead's value unit.
  public struct Goal: Hashable, Sendable {
    public var value: Double

    public init(value: Double) {
      self.value = value
    }
  }

  /// The series or formula the header, Summary's headline, the goal and the display unit go by:
  /// the first visible series, or with every series hidden, the first visible formula.
  public enum Lead: Hashable, Sendable {
    case series(Series)
    case formula(Formula)
  }

  public var lead: Lead? {
    if let series = series.first(where: { !$0.hidden }) { return .series(series) }
    if let formula = formulas.first(where: { !$0.hidden }) { return .formula(formula) }
    return nil
  }

  /// The series a formula's unit and type come from: its (first) series.
  public func leadingSeries(of formula: Formula) -> Series? {
    let id = formula.operation.seriesIDs[0]
    return series.first { $0.id == id }
  }

  /// The value unit of a formula: its (first) series'.
  public func valueUnit(of formula: Formula) -> CardValueUnit? {
    leadingSeries(of: formula)?.valueUnit
  }

  /// The type the lead's values are of: the lead series', or a formula's first series'. Its
  /// locale's unit is the card's display unit when it doesn't pin one.
  public var leadType: String? {
    switch lead {
    case .series(let series): series.type
    case .formula(let formula): leadingSeries(of: formula)?.type
    case nil: nil
    }
  }

  /// The lead's value unit, which every visible line shares.
  public var valueUnit: CardValueUnit? {
    switch lead {
    case .series(let series): series.valueUnit
    case .formula(let formula): valueUnit(of: formula)
    case nil: nil
    }
  }
}

/// The unit of a series' values.
public enum CardValueUnit: Hashable, Sendable, CustomStringConvertible {
  /// The type's catalog unit, as an `HKUnit` string.
  case catalog(String)
  /// A number of readings (`count` series): its own dimension, never converted.
  case readings

  /// The unit string: `count` for readings.
  public var description: String {
    switch self {
    case .catalog(let unit): unit
    case .readings: "count"
    }
  }
}

/// A `timeOfDay` window: from `from` up to `to` on the local clock, every day, crossing midnight
/// when `from` is later than `to` (`22:00` to `06:00`). A reading is in it by its start's clock
/// time in the engine's calendar, so on the day clocks go forward a window over the skipped hour
/// is an hour shorter, and on the day they go back the repeated hour counts twice.
public struct CardTimeOfDay: Hashable, Sendable {
  public var from: CardClockTime
  public var to: CardClockTime

  public init(from: CardClockTime, to: CardClockTime) {
    self.from = from
    self.to = to
  }

  /// Whether a clock time, in seconds since the local midnight (0 to 86,399, fractions included),
  /// is in the window.
  public func contains(secondsSinceMidnight seconds: Double) -> Bool {
    let from = Double(self.from.secondsSinceMidnight)
    let to = Double(self.to.secondsSinceMidnight)
    return from < to ? (from <= seconds && seconds < to) : (seconds >= from || seconds < to)
  }
}

/// A time on the 24-hour clock, to the minute: `"07:30"`.
public struct CardClockTime: Hashable, Sendable, CustomStringConvertible {
  public let hour: Int
  public let minute: Int

  public init?(hour: Int, minute: Int) {
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    self.hour = hour
    self.minute = minute
  }

  /// `HH:MM`, two digits each, from `00:00` to `23:59`.
  public init?(_ text: String) {
    let scalars = Array(text.unicodeScalars)
    guard scalars.count == 5, scalars[2] == ":",
      [0, 1, 3, 4].allSatisfy({ ("0"..."9").contains(scalars[$0]) })
    else { return nil }
    func number(_ index: Int) -> Int {
      Int(scalars[index].value - 48) * 10 + Int(scalars[index + 1].value - 48)
    }
    self.init(hour: number(0), minute: number(3))
  }

  public var secondsSinceMidnight: Int { hour * 3600 + minute * 60 }

  /// `HH:MM`.
  public var description: String {
    (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
  }
}

/// The period a card shows, as Metric Detail has them.
public enum CardRange: String, CaseIterable, Hashable, Sendable {
  case day = "D"
  case week = "W"
  case month = "M"
  case sixMonths = "6M"
  case year = "Y"
}

// MARK: - JSON

extension CardSpec {
  /// The canonical form: every field, keys in the design's order.
  public var json: CardJSON {
    [
      "version": .number(Double(version)),
      "display": [
        "name": .string(display.name),
        "symbol": .string(display.symbol),
        "color": .string(display.color.rawValue),
        "unit": display.unit.map(CardJSON.string) ?? .null,
      ],
      "series": .array(series.map(\.json)),
      "formulas": .array(formulas.map(\.json)),
      "bucket": .string(bucket.rawValue),
      "range": .string(range.rawValue),
      "chart": [
        "style": .string(chart.style.rawValue),
        "goal": chart.goal.map { ["value": .number($0.value)] } ?? .null,
      ],
    ]
  }

  /// The canonical form as compact JSON text, the way apps and tools write and measure it.
  public var jsonText: String { json.text() }
}

extension CardSpec.Series {
  var json: CardJSON {
    [
      "id": .string(id),
      "type": .string(type),
      "aggregation": .string(aggregation.rawValue),
      "window": window?.json ?? .null,
      "filter": filter?.json ?? .null,
      "label": label.map(CardJSON.string) ?? .null,
      "hidden": .bool(hidden),
    ]
  }
}

extension CardSpec.Window {
  var json: CardJSON {
    switch self {
    case .asleep: ["kind": "asleep"]
    case .beforeSleep(let minutes): ["kind": "beforeSleep", "minutes": .number(Double(minutes))]
    case .afterWaking(let minutes): ["kind": "afterWaking", "minutes": .number(Double(minutes))]
    case .workout(let activities):
      [
        "kind": "workout",
        "activities": activities.map { .array($0.map { .number(Double($0)) }) } ?? .null,
      ]
    case .timeOfDay(let window):
      [
        "kind": "timeOfDay", "from": .string(window.from.description),
        "to": .string(window.to.description),
      ]
    }
  }
}

extension CardSpec.Filter {
  var json: CardJSON {
    [
      "sources": sources.map { .array($0.map(CardJSON.string)) } ?? .null,
      "deviceModels": deviceModels.map { .array($0.map(CardJSON.string)) } ?? .null,
    ]
  }
}

extension CardSpec.Formula {
  var json: CardJSON {
    var members: [(key: String, value: CardJSON)] = [
      ("id", .string(id)), ("kind", .string(operation.kind.rawValue)),
    ]
    switch operation {
    case .movingAverage(let of, let points):
      members += [("of", .string(of)), ("points", .number(Double(points)))]
    case .difference(let a, let b):
      members += [("of", [.string(a), .string(b)])]
    }
    members += [("label", label.map(CardJSON.string) ?? .null), ("hidden", .bool(hidden))]
    return .object(members)
  }
}

extension CardSpec: Codable {
  /// Decodes any valid spec, canonicalizing it, and throws a `DecodingError` with every error
  /// otherwise, a later version's included (`unsupportedVersion`). Up to the store's 16 KB, so a
  /// spec another writer wrote just under it still reads.
  public init(from decoder: any Decoder) throws {
    let json = try CardJSON(from: decoder)
    switch CardSpecValidator.canonicalize(json, sizeLimit: HealthCards.storeMaxSpecBytes) {
    case .success(let spec):
      self = spec
    case .failure(let error):
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.description))
    }
  }

  /// Encodes the canonical form.
  public func encode(to encoder: any Encoder) throws {
    try json.encode(to: encoder)
  }
}
