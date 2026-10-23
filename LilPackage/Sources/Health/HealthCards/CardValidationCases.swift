// The shared validation cases' inputs (`Services/api/test/health/cards/validation-cases.json`):
// every rule, its edges, and the design's examples. The file records what this module gives for
// each, and the server's port must give the same. `HealthCardsTests` checks the messages
// themselves. Synthetic values only.

enum CardValidationCases {
  enum Mode: String {
    /// `CardSpec(input:)`, as apps and tools canonicalize.
    case input
    /// `CardSpec.storedErrors`, the store's check.
    case stored
  }

  struct Case {
    let name: String
    let mode: Mode
    let spec: CardJSON
  }

  static let heartRate: CardJSON = "HKQuantityTypeIdentifierHeartRate"
  static let hrv: CardJSON = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
  static let steps: CardJSON = "HKQuantityTypeIdentifierStepCount"
  static let weight: CardJSON = "HKQuantityTypeIdentifierBodyMass"
  static let bodyTemperature: CardJSON = "HKQuantityTypeIdentifierBodyTemperature"
  static let restingHeartRate: CardJSON = "HKQuantityTypeIdentifierRestingHeartRate"

  /// A spec of version 1 named "Card", with the series given and the other fields only if given.
  static func spec(
    _ series: CardJSON..., formulas: CardJSON? = nil, bucket: CardJSON? = nil,
    range: CardJSON? = nil, chart: CardJSON? = nil, display: CardJSON = ["name": "Card"]
  ) -> CardJSON {
    var members: [(key: String, value: CardJSON)] = [
      ("version", 1), ("display", display), ("series", .array(series)),
    ]
    if let formulas { members.append(("formulas", formulas)) }
    if let bucket { members.append(("bucket", bucket)) }
    if let range { members.append(("range", range)) }
    if let chart { members.append(("chart", chart)) }
    return .object(members)
  }

  static func input(_ name: String, _ spec: CardJSON) -> Case {
    Case(name: name, mode: .input, spec: spec)
  }

  static func stored(_ name: String, _ spec: CardJSON) -> Case {
    Case(name: name, mode: .stored, spec: spec)
  }

  /// A filter of 10 sources of 200 characters each: about 2 KB.
  static let largeFilter: CardJSON = [
    "sources": .array(
      (0..<10).map { .string("com.example.source\($0)." + String(repeating: "x", count: 180)) })
  ]

  /// The largest filter: 10 sources and 10 device models of 200 characters each, about 4 KB.
  static let largestFilter: CardJSON = [
    "sources": .array(
      (0..<10).map { .string("com.example.source\($0)." + String(repeating: "x", count: 180)) }),
    "deviceModels": .array(
      (0..<10).map { .string("Model \($0) " + String(repeating: "m", count: 192)) }),
  ]

  static let specs: [Case] = [
    // MARK: Canonical forms
    input("The least a spec needs, defaults filled in", spec(["type": heartRate])),
    input(
      "Types by name and short identifier, in any case",
      spec(["type": "heart rate"], ["type": "RESTINGHEARTRATE"], display: ["name": "Heart"])),
    input(
      "Names and labels trimmed, lengths in code points",
      spec(
        ["type": weight, "label": "\u{3000}Mañana \u{1F44D}\u{1F3FD} "],
        display: ["name": "\t Peso 🏋️‍♀️ (kg) \n"])),
    input(
      "Nulls take defaults",
      .object([
        ("version", 1),
        ("display", ["name": "Steps", "symbol": nil, "color": nil, "unit": nil]),
        (
          "series",
          [
            [
              "id": nil, "type": steps, "aggregation": nil, "window": nil, "filter": nil,
              "label": nil, "hidden": nil,
            ]
          ]
        ),
        ("formulas", nil), ("bucket", nil), ("range", nil), ("chart", nil),
      ])),
    input(
      "A count of heart rate readings draws dots, not ranges",
      spec(["type": heartRate, "aggregation": "count"])),
    input("Weight draws a line in its category's color", spec(["type": weight])),
    input("Bucket week opens on M", spec(["type": weight], bucket: "week")),
    input("Bucket month opens on 6M", spec(["type": weight], bucket: "month")),
    input("Bucket hour opens on W", spec(["type": heartRate], bucket: "hour", range: "D")),
    input(
      "Workout activities by raw value and name",
      spec(
        [
          "type": heartRate,
          "window": ["kind": "workout", "activities": [37, "cycling", "Hiking"]],
        ],
        bucket: "day", chart: ["style": "ranges"], display: ["name": "Heart Rate on Runs"])),
    input(
      "Every workout",
      spec(["type": heartRate, "window": ["kind": "workout"]], display: ["name": "Workout HR"])),
    input(
      "A filter of sources and device models",
      spec([
        "type": heartRate,
        "filter": [
          "sources": ["com.apple.health.81D5E1C2-0000-4000-8000-000000000001"],
          "deviceModels": ["Watch"],
        ],
      ])),
    input(
      "A filter of device models only",
      spec(["type": heartRate, "filter": ["deviceModels": ["iPhone"]]])),
    input(
      "Formulas' defaults: f1, 7 points",
      spec(["type": hrv], formulas: [["kind": "movingAverage", "of": "a"]])),
    input(
      "A display unit of the lead's dimension",
      spec(["type": bodyTemperature], display: ["name": "Temperature", "unit": "degF"])),
    input("Weight in stones", spec(["type": weight], display: ["name": "Weight", "unit": "st"])),
    input("Steps with a goal", spec(["type": steps], chart: ["goal": ["value": 10000]])),
    input("A goal of 0", spec(["type": weight], chart: ["goal": ["value": 0]])),
    input(
      "A fractional goal",
      spec(["type": bodyTemperature], chart: ["style": "dots", "goal": ["value": 37.5]])),
    input(
      "Example 1: body temperature",
      .object([
        ("version", 1),
        (
          "display",
          ["name": "Body Temperature", "symbol": "thermometer.medium", "color": "red", "unit": nil]
        ),
        (
          "series",
          [
            [
              "id": "a", "type": bodyTemperature, "aggregation": "avg", "window": nil,
              "filter": nil, "label": nil, "hidden": false,
            ]
          ]
        ),
        ("formulas", []), ("bucket", "auto"), ("range", "M"),
        ("chart", ["style": "line", "goal": nil]),
      ])),
    input(
      "Example 2: sleeping heart rate",
      spec(
        ["type": heartRate, "window": ["kind": "asleep"]], bucket: "night", range: "M",
        chart: ["style": "line"],
        display: ["name": "Sleeping Heart Rate", "symbol": "moon.zzz.fill", "color": "indigo"])),
    input(
      "Example 3: HRV with a moving average",
      spec(
        ["type": hrv],
        formulas: [["id": "trend", "kind": "movingAverage", "of": "a", "points": 7]],
        range: "M", chart: ["style": "dots"],
        display: ["name": "HRV", "symbol": "waveform.path.ecg", "color": "pink"])),
    input(
      "Example 4, as an agent may write it",
      spec(
        ["type": "Heart Rate", "window": ["kind": "beforeSleep", "minutes": 5]], bucket: "night",
        range: "M", chart: ["style": "dots"],
        display: ["name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint"])),
    input(
      "Sleeping heart rate minus resting heart rate",
      spec(
        ["type": heartRate, "window": ["kind": "asleep"], "hidden": true],
        ["type": restingHeartRate, "hidden": true],
        formulas: [
          ["id": "gap", "kind": "difference", "of": ["a", "b"], "label": "Above resting"]
        ],
        bucket: "night", display: ["name": "Sleeping HR Above Resting"])),
    input(
      "Heart rate after waking, by week",
      spec(
        ["type": heartRate, "window": ["kind": "afterWaking", "minutes": 240]], bucket: "week",
        range: "Y", chart: ["style": "line"])),
    input(
      "Four visible lines",
      spec(
        ["type": heartRate], ["type": restingHeartRate], ["type": "Walking Heart Rate Average"],
        formulas: [["kind": "movingAverage", "of": "a", "points": 30]], chart: ["style": "line"])),
    input(
      "A hidden series and its formula",
      spec(
        ["type": hrv, "hidden": true],
        formulas: [["kind": "movingAverage", "of": "a", "points": 2]])),
    input(
      "A formula leads when every series is hidden, and sets the display unit's dimension",
      spec(
        ["type": weight, "hidden": true], formulas: [["kind": "movingAverage", "of": "a"]],
        chart: ["goal": ["value": 70]], display: ["name": "Weight trend", "unit": "lb"])),

    // MARK: Shape
    input("Not an object", []),
    input(
      "Wrong types everywhere",
      .object([
        ("version", "1"),
        ("display", ["name": 5, "symbol": true, "color": 1, "unit": 2]),
        (
          "series",
          [
            [
              "id": 1, "type": 2, "aggregation": 3, "window": "asleep", "filter": [], "label": 4,
              "hidden": "no",
            ]
          ]
        ),
        ("formulas", ["kind": "movingAverage"]),
        ("bucket", 1), ("range", 1), ("chart", ["style": 1, "goal": 5]),
      ])),
    input(
      "display, series and chart of the wrong type",
      .object([
        ("version", 1), ("display", "Card"), ("series", ["type": heartRate]), ("chart", "line"),
      ])),
    input("A series that isn't an object", spec("HeartRate")),
    input("A formula that isn't an object", spec(["type": hrv], formulas: ["a"])),
    input("Required fields", .object([("display", [:]), ("series", [[:]])])),
    input("No display or series", ["version": 1]),
    input(
      "Unknown fields, sorted, at every level",
      .object([
        ("version", 1), ("zebra", 1), ("Display", 1),
        ("display", ["name": "Card", "colour": "red"]),
        (
          "series",
          [
            [
              "type": heartRate, "window": ["kind": "asleep", "minutes": 5],
              "filter": ["models": ["Watch"]], "units": "bpm",
            ]
          ]
        ),
        ("formulas", [["kind": "difference", "of": ["a", "a"], "points": 7]]),
        ("bucket", "night"),
        ("chart", ["style": "line", "goal": ["value": 1, "label": "Goal"], "axis": "left"]),
      ])),
    input(
      "Unknown values",
      spec(
        ["type": heartRate, "aggregation": "median"],
        ["type": heartRate, "window": ["kind": "nap"]],
        formulas: [["kind": "ratio", "of": "a"]], bucket: "year", range: "2W",
        chart: ["style": "area"])),
    input("Version 2", .object([("version", 2), ("display", ["name": 1]), ("bogus", true)])),
    input("Version 1.5", .object([("version", 1.5), ("display", ["name": "Card"])])),
    input("Version 0", .object([("version", 0)])),

    // MARK: Display
    input(
      "A name of 41 characters",
      spec(["type": heartRate], display: ["name": .string(String(repeating: "n", count: 41))])),
    input(
      "A name of 40 characters, the most",
      spec(["type": heartRate], display: ["name": .string(String(repeating: "é", count: 40))])),
    input(
      "A name of only spaces", spec(["type": heartRate], display: ["name": " \u{A0}\u{FEFF} "])),
    input(
      "A name of 20 flags is 40 code points",
      spec(["type": heartRate], display: ["name": .string(String(repeating: "🇬🇧", count: 20))])),
    input(
      "A name of 21 flags is 42 code points",
      spec(["type": heartRate], display: ["name": .string(String(repeating: "🇬🇧", count: 21))])),
    input("A line break in a name", spec(["type": heartRate], display: ["name": "Heart\nRate"])),
    input(
      "A control character in a name",
      spec(["type": heartRate], display: ["name": "Heart\u{7}Rate"])),
    input(
      "A line separator in a name",
      spec(["type": heartRate], display: ["name": "Heart\u{2028}Rate"])),
    input(
      "A symbol with close ones",
      spec(["type": heartRate], display: ["name": "HR", "symbol": "heart.circle.fil"])),
    input(
      "A symbol with none close",
      spec(["type": heartRate], display: ["name": "HR", "symbol": "xyzzy"])),
    input(
      "A symbol in the wrong case",
      spec(["type": heartRate], display: ["name": "HR", "symbol": "Heart.Fill"])),
    input(
      "A color that isn't in the palette",
      spec(["type": heartRate], display: ["name": "HR", "color": "crimson"])),
    input(
      "A color in the wrong case",
      spec(["type": heartRate], display: ["name": "HR", "color": "Red"])),
    input(
      "A unit of another dimension",
      spec(["type": bodyTemperature], display: ["name": "Temp", "unit": "lb"])),
    input(
      "A unit for a type with no others",
      spec(["type": heartRate], display: ["name": "HR", "unit": "lb"])),
    input(
      "A unit for a count",
      spec(["type": weight, "aggregation": "count"], display: ["name": "Weigh-ins", "unit": "kg"])),
    input(
      "A unit that doesn't exist",
      spec(["type": weight], display: ["name": "Weight", "unit": "furlong"])),
    input(
      "A unit for a formula lead",
      spec(
        ["type": hrv, "hidden": true], formulas: [["kind": "movingAverage", "of": "a"]],
        display: ["name": "HRV", "unit": "s"])),

    // MARK: Series
    input("No series", spec()),
    input(
      "Five series",
      spec(
        ["type": heartRate], ["type": heartRate], ["type": heartRate], ["type": heartRate],
        ["type": heartRate])),
    input(
      "IDs that don't fit",
      spec(
        ["id": "A1", "type": heartRate], ["id": "1a", "type": heartRate],
        ["id": "abcdefghijklmnopq", "type": heartRate], ["id": "", "type": heartRate])),
    input("An ID of 16 characters, the most", spec(["id": "abcdefghijklmnop", "type": heartRate])),
    input(
      "Duplicate series IDs",
      spec(["id": "a", "type": heartRate], ["id": "a", "type": restingHeartRate])),
    input("A default ID taken", spec(["id": "b", "type": heartRate], ["type": restingHeartRate])),
    input(
      "A series' ID taken by a formula",
      spec(["type": hrv], formulas: [["id": "a", "kind": "movingAverage", "of": "a"]])),
    input(
      "A formula's ID taken",
      spec(
        ["type": hrv],
        formulas: [
          ["id": "t", "kind": "movingAverage", "of": "a"],
          ["id": "t", "kind": "movingAverage", "of": "a", "points": 30],
        ])),
    input("A type with a close one", spec(["type": "HeartRat"])),
    input("A type of two words with a close one", spec(["type": "heart variab"])),
    input("A type with none close", spec(["type": "Xyzzy"])),
    input("Sleep isn't a quantity", spec(["type": "Sleep"])),
    input("Workouts aren't a quantity", spec(["type": "HKWorkoutTypeIdentifier"])),
    input("Mindful minutes aren't a quantity", spec(["type": "Mindful Minutes"])),
    input(
      "A characteristic isn't a quantity",
      spec(["type": "HKCharacteristicTypeIdentifierDateOfBirth"])),
    input("A type apps can't read", spec(["type": "NikeFuel"])),
    input("Steps averaged", spec(["type": steps, "aggregation": "avg"])),
    input("Heart rate summed", spec(["type": heartRate, "aggregation": "sum"])),
    input(
      "Every aggregation a discrete type takes",
      spec(
        ["type": heartRate, "aggregation": "avg"], ["type": heartRate, "aggregation": "min"],
        ["type": heartRate, "aggregation": "max"], ["type": heartRate, "aggregation": "latest"],
        chart: ["style": "line"])),
    input(
      "A window on steps", spec(["type": steps, "window": ["kind": "asleep"]], bucket: "night")),
    input("A filter on steps", spec(["type": steps, "filter": ["deviceModels": ["Watch"]]])),
    input(
      "Window minutes out of range",
      spec(
        ["type": heartRate, "window": ["kind": "beforeSleep", "minutes": 0]],
        ["type": heartRate, "window": ["kind": "beforeSleep", "minutes": 241]],
        ["type": heartRate, "window": ["kind": "afterWaking", "minutes": 2.5]],
        ["type": heartRate, "window": ["kind": "afterWaking", "minutes": "5"]],
        bucket: "night")),
    input(
      "Window minutes missing",
      spec(
        ["type": heartRate, "window": ["kind": "beforeSleep"]],
        ["type": heartRate, "window": ["kind": "afterWaking", "minutes": nil]], bucket: "night")),
    input(
      "A window without a kind",
      spec(["type": heartRate, "window": ["minutes": 5]], bucket: "night")),
    input(
      "Activities that don't exist",
      spec([
        "type": heartRate,
        "window": ["kind": "workout", "activities": [999, "Runing", 37.5, true, -1]],
      ])),
    input(
      "No activities", spec(["type": heartRate, "window": ["kind": "workout", "activities": []]])),
    input(
      "Eleven activities",
      spec([
        "type": heartRate,
        "window": ["kind": "workout", "activities": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]],
      ])),
    input(
      "An activity twice",
      spec([
        "type": heartRate,
        "window": ["kind": "workout", "activities": [37, "running", "Cycling", 13]],
      ])),
    input(
      "Activities that aren't a list",
      spec(["type": heartRate, "window": ["kind": "workout", "activities": "Running"]])),
    input(
      "An empty filter",
      spec(
        ["type": heartRate, "filter": [:]],
        ["type": heartRate, "filter": ["sources": nil, "deviceModels": nil]])),
    input(
      "Filter lists of 0 and 11",
      spec([
        "type": heartRate,
        "filter": [
          "sources": [], "deviceModels": ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"],
        ],
      ])),
    input(
      "Filter values that don't fit",
      spec([
        "type": heartRate,
        "filter": [
          "sources": ["", .string(String(repeating: "s", count: 201)), 5], "deviceModels": "Watch",
        ],
      ])),
    input(
      "A filter value of 200 characters, the most",
      spec([
        "type": heartRate, "filter": ["sources": [.string(String(repeating: "s", count: 200))]],
      ])),
    input(
      "Labels that don't fit",
      spec(
        ["type": heartRate, "label": "  "],
        ["type": heartRate, "label": .string(String(repeating: "l", count: 41))],
        ["type": heartRate, "label": "a\tb"])),

    // MARK: Formulas
    input(
      "Three formulas",
      spec(
        ["type": hrv],
        formulas: [
          ["kind": "movingAverage", "of": "a"], ["kind": "movingAverage", "of": "a"],
          ["kind": "movingAverage", "of": "a"],
        ])),
    input(
      "Moving average points out of range",
      spec(
        ["type": hrv],
        formulas: [
          ["kind": "movingAverage", "of": "a", "points": 1],
          ["kind": "movingAverage", "of": "a", "points": 31],
        ], chart: ["style": "dots"])),
    input(
      "Points that aren't whole",
      spec(["type": hrv], formulas: [["kind": "movingAverage", "of": "a", "points": 7.5]])),
    input(
      "A formula of a series that isn't there",
      spec(["type": hrv], formulas: [["kind": "movingAverage", "of": "c"]])),
    input(
      "A formula of a formula",
      spec(
        ["type": hrv],
        formulas: [
          ["id": "t", "kind": "movingAverage", "of": "a"],
          ["kind": "difference", "of": ["a", "t"]],
        ])),
    input(
      "Formulas without kind or of",
      spec(
        ["type": hrv], formulas: [["of": "a"], ["kind": "movingAverage"], ["kind": "difference"]])),
    input(
      "A difference of one series",
      spec(["type": hrv], formulas: [["kind": "difference", "of": ["a"]]])),
    input(
      "A difference of a string",
      spec(["type": hrv], formulas: [["kind": "difference", "of": "a"]])),
    input(
      "A moving average of a list",
      spec(["type": hrv], formulas: [["kind": "movingAverage", "of": ["a"]]])),
    input(
      "A difference of two units",
      spec(
        ["type": heartRate, "hidden": true], ["type": hrv, "hidden": true],
        formulas: [["kind": "difference", "of": ["a", "b"]]])),

    // MARK: Across fields
    input(
      "Two units on one axis", spec(["type": heartRate], ["type": hrv], chart: ["style": "dots"])),
    input(
      "A count beside an average of the same type",
      spec(["type": weight], ["type": weight, "aggregation": "count"])),
    input(
      "Steps beside a count, both in count",
      spec(["type": steps], ["type": heartRate, "aggregation": "count"])),
    input(
      "A formula of another unit",
      spec(
        ["type": heartRate], ["type": hrv, "hidden": true],
        formulas: [["kind": "movingAverage", "of": "b"]], chart: ["style": "dots"])),
    input(
      "Everything hidden",
      spec(
        ["type": hrv, "hidden": true],
        formulas: [["kind": "movingAverage", "of": "a", "hidden": true]])),
    input(
      "Five visible lines",
      spec(
        ["type": heartRate], ["type": heartRate], ["type": heartRate], ["type": heartRate],
        formulas: [["kind": "movingAverage", "of": "a"]], chart: ["style": "line"])),
    input(
      "Night without a sleep window",
      spec(["type": heartRate, "window": ["kind": "workout"]], bucket: "night")),
    input(
      "A sleep window by day",
      spec(["type": heartRate, "window": ["kind": "asleep"]], bucket: "day")),
    input(
      "A sleep window by auto",
      spec(["type": heartRate, "window": ["kind": "beforeSleep", "minutes": 5]])),
    input(
      "A sleep window by hour",
      spec(["type": heartRate, "window": ["kind": "afterWaking", "minutes": 30]], bucket: "hour")),
    input(
      "A sleep window by month",
      spec(["type": heartRate, "window": ["kind": "asleep"]], bucket: "month")),
    input(
      "Night with a series without a window",
      spec(
        ["type": heartRate, "window": ["kind": "asleep"]], ["type": restingHeartRate],
        bucket: "night")),
    input("Y by hour", spec(["type": heartRate], bucket: "hour", range: "Y")),
    input("M by hour", spec(["type": heartRate], bucket: "hour", range: "M")),
    input("6M by hour", spec(["type": heartRate], bucket: "hour", range: "6M")),
    input("D by day", spec(["type": heartRate], bucket: "day", range: "D")),
    input("W by week", spec(["type": weight], bucket: "week", range: "W")),
    input("M by month", spec(["type": weight], bucket: "month", range: "M")),
    input("Ranges of steps", spec(["type": steps], chart: ["style": "ranges"])),
    input(
      "Ranges of a count",
      spec(["type": heartRate, "aggregation": "count"], chart: ["style": "ranges"])),
    input(
      "Ranges with a hidden total",
      spec(
        ["type": heartRate], ["type": heartRate, "aggregation": "count", "hidden": true],
        chart: ["style": "ranges"])),
    input("A negative goal", spec(["type": heartRate], chart: ["goal": ["value": -1]])),
    input(
      "A goal that isn't a number", spec(["type": heartRate], chart: ["goal": ["value": "high"]])),
    input(
      "A negative goal for a count",
      spec(["type": heartRate, "aggregation": "count"], chart: ["goal": ["value": -5]])),
    input(
      "A negative goal for a formula",
      spec(
        ["type": weight, "hidden": true], formulas: [["kind": "movingAverage", "of": "a"]],
        chart: ["goal": ["value": -70]])),
    input(
      "A negative goal with an unknown lead",
      spec(["type": "Xyzzy"], chart: ["goal": ["value": -1]])),
    input("A goal without a value", spec(["type": heartRate], chart: ["goal": [:]])),

    // MARK: Many at once
    input(
      "Several errors, in order",
      .object([
        ("version", 1),
        ("display", ["name": "", "symbol": "heart.circle", "color": "crimson", "unit": "lb"]),
        (
          "series",
          [
            ["type": "HeartRat"],
            ["type": steps, "aggregation": "avg", "window": ["kind": "asleep"]],
            ["type": hrv, "label": ""],
          ]
        ),
        ("formulas", [["id": "a", "kind": "movingAverage", "of": "z", "points": 99]]),
        ("bucket", "day"), ("range", "D"),
        ("chart", ["style": "ranges", "goal": ["value": -1]]),
      ])),
    input(
      "More than 20 errors: the first 20",
      .object([
        ("version", 1),
        ("display", ["name": "", "symbol": "x", "color": "x", "unit": 1, "a": 1, "b": 1]),
        (
          "series",
          [
            ["id": "A", "type": "x", "aggregation": "x", "label": "", "hidden": 1, "c": 1],
            ["id": "B", "type": "y", "aggregation": "y", "label": "", "hidden": 1, "d": 1],
          ]
        ),
        ("bucket", "x"), ("range", "x"), ("chart", ["style": "x", "e": 1]), ("f", 1),
      ])),

    // MARK: Size
    input(
      "Over 8 KB",
      spec(
        ["type": heartRate, "filter": largeFilter], ["type": heartRate, "filter": largeFilter],
        ["type": heartRate, "filter": largeFilter], ["type": heartRate, "filter": largeFilter],
        chart: ["style": "dots"])),

    // MARK: Stored
    stored("A seed card, canonical", HealthCards.welcomeSeed[1].spec.json),
    stored(
      "Example 4, canonical",
      (try? CardSpec(
        input: spec(
          ["type": "Heart Rate", "window": ["kind": "beforeSleep", "minutes": 5]], bucket: "night",
          range: "M", chart: ["style": "dots"],
          display: [
            "name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint",
          ])))?.json ?? nil),
    stored(
      "Canonical, keys in another order",
      .object([
        ("chart", ["goal": nil, "style": "ranges"]), ("range", "W"), ("bucket", "auto"),
        ("formulas", []),
        (
          "series",
          [
            [
              "hidden": false, "label": nil, "filter": nil, "window": nil, "aggregation": "avg",
              "type": heartRate, "id": "a",
            ]
          ]
        ),
        ("display", ["unit": nil, "color": "red", "symbol": "heart.fill", "name": "Heart Rate"]),
        ("version", 1.0),
      ])),
    stored("Defaults left out", spec(["type": heartRate])),
    stored(
      "A type by name",
      .object([
        ("version", 1),
        ("display", ["name": "Heart Rate", "symbol": "heart.fill", "color": "red", "unit": nil]),
        (
          "series",
          [
            [
              "id": "a", "type": "Heart Rate", "aggregation": "avg", "window": nil, "filter": nil,
              "label": nil, "hidden": false,
            ]
          ]
        ),
        ("formulas", []), ("bucket", "auto"), ("range", "W"),
        ("chart", ["style": "ranges", "goal": nil]),
      ])),
    stored(
      "A name not trimmed",
      .object([
        ("version", 1),
        ("display", ["name": "Heart Rate ", "symbol": "heart.fill", "color": "red", "unit": nil]),
        (
          "series",
          [
            [
              "id": "a", "type": heartRate, "aggregation": "avg", "window": nil, "filter": nil,
              "label": nil, "hidden": false,
            ]
          ]
        ),
        ("formulas", []), ("bucket", "auto"), ("range", "W"),
        ("chart", ["style": "ranges", "goal": nil]),
      ])),
    stored("A later version", .object([("version", 2), ("display", ["name": "From the future"])])),
    stored("Invalid", spec(["type": heartRate, "aggregation": "sum"])),
    stored(
      "Over 8 KB, under the store's 16 KB",
      (try? CardSpecValidator.canonicalize(
        spec(
          ["type": heartRate, "filter": largeFilter], ["type": heartRate, "filter": largeFilter],
          ["type": heartRate, "filter": largeFilter], ["type": heartRate, "filter": largeFilter],
          chart: ["style": "dots"]),
        sizeLimit: .max
      ).get())?.json ?? nil),
    stored(
      "Over 16 KB",
      spec(
        ["type": heartRate, "filter": largestFilter], ["type": heartRate, "filter": largestFilter],
        ["type": heartRate, "filter": largestFilter], ["type": heartRate, "filter": largestFilter],
        chart: ["style": "dots"])),
  ]

  // MARK: Positions

  static let between: [(String?, String?)] = [
    (nil, nil), ("a0", nil), ("a1", nil), ("a9", nil), ("az", nil), ("b0z", nil), ("Zz", nil),
    (nil, "a0"), (nil, "a1"), (nil, "Zz"), (nil, "a0V"), (nil, "A00000000000000000000000001"),
    ("a0", "a1"), ("a1", "a0"), ("a0", "a0V"), ("a0V", "a1"), ("a0", "a0G"), ("a0z", "a1"),
    ("Zz", "a0"), ("a0", "b00"), ("a0V", "a0W"), ("a0VV", "a0W"), ("a4", "a5"),
    ("zzzzzzzzzzzzzzzzzzzzzzzzzzz", nil), ("zzzzzzzzzzzzzzzzzzzzzzzzzzzV", nil),
    // Invalid: null.
    ("a0", "a0"), ("a00", nil), ("", nil), ("b1", nil), ("A00000000000000000000000000", nil),
    (nil, "a"), ("!0", nil),
  ]

  static let betweenCount: [(String?, String?, Int)] = [
    (nil, nil, 0), (nil, nil, 1), (nil, nil, 6), ("a5", nil, 3), (nil, "a0", 3), ("a0", "a1", 5),
    ("a1", "a0", 2), ("a0", "a0", 2),
  ]

  static let positions: [String] = [
    "a0", "a5", "Zz", "a0V", "b10", "A00000000000000000000000001", "zzzzzzzzzzzzzzzzzzzzzzzzzzzV",
    "", String(repeating: "a", count: 201), "a0" + String(repeating: "V", count: 198), "a00",
    "a0!", "b1", "a", "!", "A00000000000000000000000000", "a0é",
  ]
}
