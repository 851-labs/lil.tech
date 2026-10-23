import Foundation
import HealthCatalog
import Testing

@testable import HealthCards

/// Every rule, with its code, path and message word for word (docs/decisions/cards.md,
/// Validation and errors). The design's example messages are kept where they fit.
struct CardSpecValidationTests {
  struct Example: CustomTestStringConvertible, Sendable {
    let name: String
    let spec: String
    let errors: [String]
    var testDescription: String { name }

    init(_ name: String, _ spec: String, _ errors: String...) {
      self.name = name
      self.spec = spec
      self.errors = errors
    }
  }

  /// `path | code | message` for each error, or none.
  static func errors(_ spec: String) -> [String] {
    do {
      _ = try CardSpec(inputJSON: Data(spec.utf8))
      return []
    } catch {
      return error.errors.map { "\($0.path) | \($0.code.rawValue) | \($0.message)" }
    }
  }

  /// A spec named "Card" with these series and other fields.
  static func card(_ series: String, _ rest: String = "") -> String {
    #"{"version": 1, "display": {"name": "Card"}, "series": [\#(series)]\#(rest.isEmpty ? "" : ", " + rest)}"#
  }

  static let hr = #"{"type": "HeartRate"}"#

  static let examples: [Example] = [
    // Shape
    Example("not an object", "[]", " | invalidType | A card spec is a JSON object."),
    Example(
      "required", #"{"display": {}, "series": [{}]}"#,
      "version | required | version is required: the spec's format, 1.",
      "display.name | required | display.name is required: what the card is called on Summary.",
      #"series[0].type | required | series[0].type is required: a quantity type, e.g. HKQuantityTypeIdentifierHeartRate or "Heart Rate"."#
    ),
    Example(
      "display and series required", #"{"version": 1}"#,
      "display | required | display is required: the card's name, and optionally its symbol, color and unit.",
      #"series | required | series is required: 1 to 4 series, e.g. [{"type": "HKQuantityTypeIdentifierHeartRate"}]."#
    ),
    Example(
      "unknown field",
      #"{"version": 1, "display": {"name": "Card", "colour": "red"}, "series": [{"type": "HeartRate"}]}"#,
      #"display.colour | unknownField | Unknown field "colour" in display. Allowed: name, symbol, color, unit."#
    ),
    Example(
      "unknown fields of the spec, sorted", card(hr, #""zebra": 1, "Apple": 2"#),
      #"Apple | unknownField | Unknown field "Apple" in the spec. Allowed: version, display, series, formulas, bucket, range, chart."#,
      #"zebra | unknownField | Unknown field "zebra" in the spec. Allowed: version, display, series, formulas, bucket, range, chart."#
    ),
    Example(
      "unknown value", card(#"{"type": "HeartRate", "aggregation": "median"}"#),
      #"series[0].aggregation | unknownValue | "median" isn't an aggregation. Use sum, avg, min, max, first, latest or count."#
    ),
    Example(
      "wrong type", card(#"{"type": "HeartRate", "hidden": "yes"}"#),
      "series[0].hidden | invalidType | series[0].hidden must be true or false."),
    Example(
      "unsupported version, the one error", #"{"version": 2, "display": 5}"#,
      "version | unsupportedVersion | version 2 isn't supported. This server reads card spec version 1."
    ),
    // Display
    Example(
      "name length",
      #"{"version": 1, "display": {"name": "\#(String(repeating: "x", count: 52))"}, "series": [{"type": "HeartRate"}]}"#,
      "display.name | nameLength | display.name must be 1 to 40 characters (it's 52)."),
    Example(
      "name length in code points",
      #"{"version": 1, "display": {"name": "\#(String(repeating: "👍🏽", count: 21))"}, "series": [{"type": "HeartRate"}]}"#,
      "display.name | nameLength | display.name must be 1 to 40 characters (it's 42)."),
    Example(
      "name characters",
      #"{"version": 1, "display": {"name": "A\nB"}, "series": [{"type": "HeartRate"}]}"#,
      "display.name | invalidCharacters | display.name can't have line breaks or control characters."
    ),
    Example(
      "unknown symbol",
      #"{"version": 1, "display": {"name": "Card", "symbol": "heart.circle.fil"}, "series": [{"type": "HeartRate"}]}"#,
      #"display.symbol | unknownSymbol | "heart.circle.fil" isn't one of lil health's card symbols. Close ones: heart.fill, heart.text.square.fill, bolt.heart.fill. The input schema lists them all."#
    ),
    Example(
      "unknown color",
      #"{"version": 1, "display": {"name": "Card", "color": "crimson"}, "series": [{"type": "HeartRate"}]}"#,
      #"display.color | unknownColor | "crimson" isn't a card color. Use one of: red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray."#
    ),
    Example(
      "unit dimension",
      #"{"version": 1, "display": {"name": "Card", "unit": "lb"}, "series": [{"type": "BodyTemperature"}]}"#,
      #"display.unit | unitDimension | "lb" isn't a unit for Body Temperature (degC). Use degC or degF, or null for the locale's."#
    ),
    Example(
      "unit for a type without others",
      #"{"version": 1, "display": {"name": "Card", "unit": "lb"}, "series": [{"type": "HeartRate"}]}"#,
      #"display.unit | unitDimension | "lb" isn't a unit for Heart Rate (count/min), which has no others: use null."#
    ),
    Example(
      "unit for a count",
      #"{"version": 1, "display": {"name": "Card", "unit": "kg"}, "series": [{"type": "Weight", "aggregation": "count"}]}"#,
      #"display.unit | unitDimension | "kg" isn't a unit for a count of Weight readings, which has no others: use null."#
    ),
    // Series
    Example(
      "series count", card(Array(repeating: hr, count: 5).joined(separator: ",")),
      "series | seriesCount | A card has 1 to 4 series (this one has 5)."),
    Example(
      "invalid id", card(#"{"id": "A", "type": "HeartRate"}"#),
      #"series[0].id | invalidID | series[0].id must be a lowercase letter, then up to 15 lowercase letters or digits, e.g. "a" or "trend" (it's "A")."#
    ),
    Example(
      "unknown type", card(#"{"type": "HeartRat"}"#),
      #"series[0].type | unknownType | "HeartRat" isn't a type lil health knows. Did you mean Heart Rate (HKQuantityTypeIdentifierHeartRate)? list_types lists them."#
    ),
    Example(
      "not a quantity", card(#"{"type": "Sleep"}"#),
      #"series[0].type | notQuantity | Sleep isn't a quantity: cards chart quantities such as heart rate or steps. To chart around sleep, use a window on a quantity, e.g. {"kind": "asleep"}."#
    ),
    Example(
      "unreadable type", card(#"{"type": "NikeFuel"}"#),
      "series[0].type | unreadableType | NikeFuel can't be read from Health by apps, so cards can't chart it."
    ),
    Example(
      "sum only", card(#"{"type": "Steps", "aggregation": "avg"}"#),
      #"series[0].aggregation | aggregationNotAllowed | Steps adds up, so it takes "sum" only (avg, min, max, first, latest and count are for types measured at points in time). For an average day over weeks or months, use bucket "auto" at 6M or Y."#
    ),
    Example(
      "no sum", card(#"{"type": "HeartRate", "aggregation": "sum"}"#),
      "series[0].aggregation | aggregationNotAllowed | Heart Rate doesn't add up: use avg, min, max, first, latest or count, not sum."
    ),
    Example(
      "window on cumulative", card(#"{"type": "Steps", "window": {"kind": "workout"}}"#),
      "series[0].window | windowOnCumulative | Windows work with types measured at points in time (heart rate, HRV), not ones that add up (Steps), in this version."
    ),
    Example(
      "window minutes",
      card(
        #"{"type": "HeartRate", "window": {"kind": "beforeSleep", "minutes": 241}}"#,
        #""bucket": "night""#),
      "series[0].window.minutes | windowMinutes | series[0].window.minutes must be a whole number from 1 to 240."
    ),
    Example(
      "window time",
      card(#"{"type": "Weight", "window": {"kind": "timeOfDay", "from": "7:30", "to": "12:00"}}"#),
      #"series[0].window.from | windowTime | series[0].window.from must be a time on the 24-hour clock, "HH:MM" from "00:00" to "23:59" (it's "7:30")."#
    ),
    Example(
      "window times the same",
      card(#"{"type": "Weight", "window": {"kind": "timeOfDay", "from": "12:00", "to": "12:00"}}"#),
      #"series[0].window | windowTime | series[0].window starts and ends at 12:00: for every reading, set window to null. A window may cross midnight, e.g. from "22:00" to "06:00"."#
    ),
    Example(
      "same series", card(hr, #""formulas": [{"kind": "difference", "of": ["a", "a"]}]"#),
      #"formulas[0].of | sameSeries | formulas[0] subtracts "a" from itself: name two different series."#
    ),
    Example(
      "unknown activity",
      card(#"{"type": "HeartRate", "window": {"kind": "workout", "activities": [37, 999]}}"#),
      #"series[0].window.activities[1] | unknownActivity | 999 isn't a workout activity. Use HKWorkoutActivityType raw values or names, e.g. 37 or "Running"."#
    ),
    Example(
      "activity count",
      card(#"{"type": "HeartRate", "window": {"kind": "workout", "activities": []}}"#),
      "series[0].window.activities | activityCount | series[0].window.activities must have 1 to 10 activities (it has 0), or be null for every workout."
    ),
    Example(
      "duplicate activity",
      card(#"{"type": "HeartRate", "window": {"kind": "workout", "activities": [37, "RUNNING"]}}"#),
      "series[0].window.activities[1] | duplicateActivity | series[0].window.activities has Running twice."
    ),
    Example(
      "filter on cumulative", card(#"{"type": "Steps", "filter": {"deviceModels": ["Watch"]}}"#),
      "series[0].filter | filterOnCumulative | Filters work with types measured at points in time, not Steps, which uses Health's de-duplicated totals."
    ),
    Example(
      "empty filter", card(#"{"type": "HeartRate", "filter": {}}"#),
      "series[0].filter | emptyFilter | A filter needs sources or deviceModels. For every source, set filter to null."
    ),
    Example(
      "filter list", card(#"{"type": "HeartRate", "filter": {"sources": []}}"#),
      "series[0].filter.sources | filterList | series[0].filter.sources must have 1 to 10 entries (it has 0), or be null."
    ),
    Example(
      "filter value", card(#"{"type": "HeartRate", "filter": {"deviceModels": [""]}}"#),
      "series[0].filter.deviceModels[0] | filterValue | series[0].filter.deviceModels[0] must be a string of 1 to 200 characters."
    ),
    Example(
      "label length", card(#"{"type": "HeartRate", "label": ""}"#),
      "series[0].label | labelLength | series[0].label must be 1 to 40 characters (it's 0), or null."
    ),
    // Formulas
    Example(
      "duplicate id",
      card(
        #"{"type": "HeartRate"}"#, #""formulas": [{"id": "a", "kind": "movingAverage", "of": "a"}]"#
      ),
      #"formulas[0].id | duplicateID | "a" is already a series' id. Each series and formula needs its own."#
    ),
    Example(
      "unknown reference",
      card(#"{"type": "HeartRate"}"#, #""formulas": [{"kind": "movingAverage", "of": "c"}]"#),
      #"formulas[0].of | unknownReference | formulas[0] refers to "c", which isn't a series of this card."#
    ),
    Example(
      "formula count",
      card(
        hr,
        #""formulas": [{"kind": "movingAverage", "of": "a"}, {"kind": "movingAverage", "of": "a"}, {"kind": "movingAverage", "of": "a"}]"#
      ),
      "formulas | formulaCount | A card has at most 2 formulas (this one has 3)."),
    Example(
      "formula points",
      card(hr, #""formulas": [{"kind": "movingAverage", "of": "a", "points": 1}]"#),
      "formulas[0].points | formulaPoints | formulas[0].points must be a whole number from 2 to 30."
    ),
    Example(
      "difference of two units",
      card(
        #"{"type": "HeartRate", "hidden": true}, {"type": "HeartRateVariabilitySDNN", "hidden": true}"#,
        #""formulas": [{"kind": "difference", "of": ["a", "b"]}]"#),
      "formulas[0].of | mixedUnits | formulas[0] subtracts Heart Rate Variability (ms) from Heart Rate (count/min): both need the same unit."
    ),
    // Across fields
    Example(
      "mixed units",
      card(
        #"{"type": "HeartRate"}, {"type": "HeartRateVariabilitySDNN"}"#,
        #""chart": {"style": "dots"}"#),
      "series[1].type | mixedUnits | Heart Rate Variability (ms) can't share a card with Heart Rate (count/min): a card has one axis. Make it a card of its own."
    ),
    Example(
      "a count is its own unit",
      card(#"{"type": "Steps"}, {"type": "HeartRate", "aggregation": "count"}"#),
      "series[1].type | mixedUnits | A count of Heart Rate readings can't share a card with Steps (count): a card has one axis. Make it a card of its own."
    ),
    Example(
      "nothing visible", card(#"{"type": "HeartRate", "hidden": true}"#),
      "series | nothingVisible | Every series and formula is hidden: leave at least one visible."),
    Example(
      "visible count",
      card(
        Array(repeating: hr, count: 4).joined(separator: ","),
        #""formulas": [{"kind": "movingAverage", "of": "a"}]"#),
      "formulas | visibleCount | A card shows at most 4 lines (series and formulas); this one has 5."
    ),
    Example(
      "night needs a sleep window", card(hr, #""bucket": "night""#),
      #"bucket | nightNeedsSleepWindow | bucket "night" needs a series with a sleep window: {"kind": "asleep"}, "beforeSleep" or "afterWaking"."#
    ),
    Example(
      "sleep window bucket",
      card(#"{"type": "HeartRate", "window": {"kind": "asleep"}}"#, #""bucket": "day""#),
      #"bucket | sleepWindowBucket | Sleep windows need bucket "night", "week" or "month": an hour or a calendar day would cut nights in two."#
    ),
    Example(
      "range not for bucket", card(hr, #""bucket": "hour", "range": "Y""#),
      #"range | rangeNotForBucket | range "Y" doesn't fit bucket "hour" (up to 8,784 points). Ranges for "hour": D, W."#
    ),
    Example(
      "ranges style", card(#"{"type": "Steps"}"#, #""chart": {"style": "ranges"}"#),
      #"chart.style | rangesStyle | "ranges" draws each bucket's lowest and highest reading, and Steps is a total. Use bars, dots or line."#
    ),
    Example(
      "goal value", card(hr, #""chart": {"goal": {"value": -1}}"#),
      "chart.goal.value | goalValue | chart.goal.value must be a number of at least 0, in count/min (Heart Rate's unit)."
    ),
  ]

  @Test(arguments: examples)
  func rule(_ example: Example) {
    #expect(Self.errors(example.spec) == example.errors)
  }

  @Test
  func everyCodeHasAnExampleOrCase() {
    let examples = Set(Self.examples.flatMap { $0.errors.map { $0.split(separator: " | ")[1] } })
    let tested = examples.union([
      "invalidJSON", "tooLarge", "notCanonical", "positionLength", "invalidPosition",
    ])
    for code in CardSpecError.Code.allCases {
      #expect(tested.contains(Substring(code.rawValue)), "\(code)")
    }
  }

  @Test
  func atMost20Errors() {
    let series = (0..<4).map { _ in
      #"{"id": "A", "type": "x", "aggregation": "x", "label": "", "hidden": 1, "z": 1}"#
    }
    let errors = Self.errors(Self.card(series.joined(separator: ","), #""bucket": "x""#))
    #expect(errors.count == HealthCards.maxErrors)
  }

  @Test
  func validInputs() {
    for spec in [
      Self.card(Self.hr),
      Self.card(#"{"type": "heart rate", "aggregation": "latest", "label": "Latest"}"#),
      Self.card(
        #"{"type": "HeartRate", "window": {"kind": "afterWaking", "minutes": 1}}"#,
        #""bucket": "month", "range": "Y""#),
      Self.card(
        #"{"type": "Weight", "hidden": true}"#,
        #""formulas": [{"kind": "movingAverage", "of": "a", "points": 30}, {"kind": "movingAverage", "of": "a", "points": 2}]"#
      ),
      Self.card(
        #"{"type": "HeartRate", "filter": {"sources": ["com.example"], "deviceModels": ["Watch"]}}"#
      ),
    ] {
      #expect(Self.errors(spec) == [], "\(spec)")
    }
  }

  @Test
  func closeSymbols() {
    #expect(HealthCards.symbolsClose(to: "moon") == ["moon.fill", "moon.zzz.fill"])
    #expect(HealthCards.symbolsClose(to: "figure.walking").contains("figure.walk"))
    #expect(HealthCards.symbolsClose(to: "qqq").isEmpty)
  }

  @Test
  func closeTypes() {
    #expect(CardSpecValidator.typeClose(to: "resting heart")?.name == "Resting Heart Rate")
    #expect(CardSpecValidator.typeClose(to: "temperatur")?.name == "Body Temperature")
    #expect(CardSpecValidator.typeClose(to: "xy") == nil)
    #expect(CardSpecValidator.typeClose(to: "   ") == nil)
  }
}
