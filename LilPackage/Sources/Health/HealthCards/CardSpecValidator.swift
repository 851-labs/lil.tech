import Foundation
import HealthCatalog

/// Canonicalizes and validates a card spec (docs/decisions/cards.md, Validation and errors).
///
/// It runs in two passes, and the server's port must find errors in the same order:
///
/// 1. **Each field,** in the spec's order (`version`, `display`, `series`, `formulas`, `bucket`,
///    `range`, `chart`), each object's fields in the table's order and then its unknown fields,
///    sorted by UTF-16 code units: shapes, values, and the rules of one series or formula.
/// 2. **Across fields:** `duplicateID`, `unknownReference` and a difference's `mixedUnits` (per
///    formula), `mixedUnits` (one axis), `nothingVisible`, `visibleCount`,
///    `nightNeedsSleepWindow`, `sleepWindowBucket`, `rangeNotForBucket`, `rangesStyle`,
///    `unitDimension`, `goalValue`.
///
/// Then, with no errors, `tooLarge` on the canonical form. At most `HealthCards.maxErrors` are
/// returned. A version it doesn't read is the one error.
struct CardSpecValidator {
  typealias Code = CardSpecError.Code

  private var errors: [CardSpecError] = []

  static func canonicalize(
    _ input: CardJSON, sizeLimit: Int
  ) -> Result<CardSpec, CardSpecValidationError> {
    var validator = CardSpecValidator()
    let spec = validator.run(input)
    if let spec, validator.errors.isEmpty {
      let bytes = spec.jsonText.utf8.count
      if bytes > sizeLimit {
        let size = (Double(bytes) * 10 / 1024).rounded(.up) / 10
        validator.fail(
          "", .tooLarge,
          "The spec is \(String(format: "%.1f", size)) KB; the limit is \(sizeLimit / 1024) KB.")
      }
    }
    guard let spec, validator.errors.isEmpty else {
      return .failure(
        CardSpecValidationError(Array(validator.errors.prefix(HealthCards.maxErrors))))
    }
    return .success(spec)
  }

  private mutating func fail(_ path: String, _ code: Code, _ message: String) {
    errors.append(CardSpecError(path: path, code: code, message: message))
  }

  // MARK: - What the first pass finds

  private struct Series {
    var path: String
    var id: String?
    var type: HealthDataType?
    var aggregation: CardSpec.Aggregation?
    var window: CardSpec.Window?
    /// The window's kind, when it's known, even if its other fields are wrong.
    var windowKind: CardSpec.Window.Kind?
    var hasWindow = false
    var filter: CardSpec.Filter?
    var label: String?
    var hidden = false

    var unit: CardValueUnit? {
      guard let aggregation else { return nil }
      if aggregation == .count { return .readings }
      return type?.unit.map(CardValueUnit.catalog)
    }
  }

  private struct Formula {
    var path: String
    var id: String?
    var kind: CardSpec.Formula.Kind?
    var of: [String]?
    var points: Int?
    var label: String?
    var hidden = false
  }

  // MARK: - First pass

  private mutating func run(_ input: CardJSON) -> CardSpec? {
    guard case .object = input else {
      fail("", .invalidType, "A card spec is a JSON object.")
      return nil
    }

    // Version
    switch input["version"] {
    case nil, .null?:
      fail("version", .required, "version is required: the spec's format, 1.")
    case .number(let version)?:
      if !(Self.isWhole(version, in: 0...1_000_000)
        && HealthCards.readableVersions.contains(Int(version)))
      {
        // Every other rule is version 1's: this is the one error.
        errors = [
          CardSpecError(
            path: "version", code: .unsupportedVersion,
            message: "version \(CardJSON.text(of: version)) isn't supported. This server reads "
              + "card spec version \(HealthCards.specVersion).")
        ]
        return nil
      }
    case _?:
      fail("version", .invalidType, "version must be a whole number: 1.")
    }

    // Display
    var name: String?
    var symbol: String?
    var color: CardColor?
    var unit: String?
    switch input["display"] {
    case nil, .null?:
      fail(
        "display", .required,
        "display is required: the card's name, and optionally its symbol, color and unit.")
    case .object(let members)?:
      let display = CardJSON.object(members)
      switch display["name"] {
      case nil, .null?:
        fail(
          "display.name", .required, "display.name is required: what the card is called on Summary."
        )
      case .string(let text)?:
        name = self.text(text, path: "display.name", code: .nameLength, orNull: false)
      case _?:
        fail("display.name", .invalidType, "display.name must be a string.")
      }
      switch display["symbol"] {
      case nil, .null?: break
      case .string(let text)?:
        if HealthCards.cardSymbols.contains(text) {
          symbol = text
        } else {
          let close = HealthCards.symbolsClose(to: text)
          let suggestion = close.isEmpty ? "" : " Close ones: \(close.joined(separator: ", "))."
          fail(
            "display.symbol", .unknownSymbol,
            "\(CardJSON.quoted(text)) isn't one of lil health's card symbols.\(suggestion) The "
              + "input schema lists them all.")
        }
      case _?:
        fail("display.symbol", .invalidType, "display.symbol must be a string.")
      }
      switch display["color"] {
      case nil, .null?: break
      case .string(let text)?:
        color = CardColor(rawValue: text)
        if color == nil {
          fail(
            "display.color", .unknownColor,
            "\(CardJSON.quoted(text)) isn't a card color. Use one of: "
              + "\(CardColor.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
      case _?:
        fail("display.color", .invalidType, "display.color must be a string.")
      }
      switch display["unit"] {
      case nil, .null?: break
      case .string(let text)?: unit = text
      case _?: fail("display.unit", .invalidType, "display.unit must be a string or null.")
      }
      unknownFields(display, path: "display", allowed: ["name", "symbol", "color", "unit"])
    case _?:
      fail("display", .invalidType, "display must be an object.")
    }

    // Series
    var series: [Series] = []
    var seriesCountIsValid = false
    switch input["series"] {
    case nil, .null?:
      fail(
        "series", .required,
        "series is required: 1 to 4 series, e.g. [{\"type\": \"HKQuantityTypeIdentifierHeartRate\"}]."
      )
    case .array(let items)?:
      seriesCountIsValid = (1...HealthCards.maxSeries).contains(items.count)
      if !seriesCountIsValid {
        fail("series", .seriesCount, "A card has 1 to 4 series (this one has \(items.count)).")
      }
      series = items.enumerated().map { parseSeries($0.element, index: $0.offset) }
    case _?:
      fail("series", .invalidType, "series must be an array of 1 to 4 series.")
    }

    // Formulas
    var formulas: [Formula] = []
    var formulaCountIsValid = true
    switch input["formulas"] {
    case nil, .null?: break
    case .array(let items)?:
      formulaCountIsValid = items.count <= HealthCards.maxFormulas
      if !formulaCountIsValid {
        fail(
          "formulas", .formulaCount, "A card has at most 2 formulas (this one has \(items.count)).")
      }
      formulas = items.enumerated().map { parseFormula($0.element, index: $0.offset) }
    case _?:
      fail("formulas", .invalidType, "formulas must be an array of up to 2 formulas.")
    }

    // Bucket and range
    var bucket: CardSpec.Bucket?
    switch input["bucket"] {
    case nil, .null?: bucket = .auto
    case .string(let text)?:
      bucket = CardSpec.Bucket(rawValue: text)
      if bucket == nil {
        fail(
          "bucket", .unknownValue,
          "\(CardJSON.quoted(text)) isn't a bucket. Use \(Self.list(CardSpec.Bucket.allCases.map(\.rawValue)))."
        )
      }
    case _?:
      fail("bucket", .invalidType, "bucket must be a string.")
    }
    var range: CardRange?
    var rangeIsExplicit = false
    switch input["range"] {
    case nil, .null?: range = bucket?.defaultRange
    case .string(let text)?:
      range = CardRange(rawValue: text)
      rangeIsExplicit = true
      if range == nil {
        fail(
          "range", .unknownValue,
          "\(CardJSON.quoted(text)) isn't a range. Use \(Self.list(CardRange.allCases.map(\.rawValue)))."
        )
      }
    case _?:
      fail("range", .invalidType, "range must be a string.")
    }

    // Chart
    var style: HealthDataType.ChartStyle?
    var styleIsExplicit = false
    var goal: CardJSON?
    var hasGoal = false
    switch input["chart"] {
    case nil, .null?: break
    case .object(let members)?:
      let chart = CardJSON.object(members)
      switch chart["style"] {
      case nil, .null?: break
      case .string(let text)?:
        styleIsExplicit = true
        style = HealthDataType.ChartStyle(rawValue: text)
        if style == nil {
          fail(
            "chart.style", .unknownValue,
            "\(CardJSON.quoted(text)) isn't a chart style. Use \(Self.list(Self.styles)).")
        }
      case _?:
        fail("chart.style", .invalidType, "chart.style must be a string.")
      }
      switch chart["goal"] {
      case nil, .null?: break
      case .object(let members)?:
        hasGoal = true
        let goalObject = CardJSON.object(members)
        switch goalObject["value"] {
        case nil, .null?:
          fail(
            "chart.goal.value", .required,
            "chart.goal.value is required: where the goal line is drawn. Or set goal to null.")
        case let value?: goal = value
        }
        unknownFields(goalObject, path: "chart.goal", allowed: ["value"])
      case _?:
        fail(
          "chart.goal", .invalidType,
          "chart.goal must be an object, e.g. {\"value\": 10000}, or null.")
      }
      unknownFields(chart, path: "chart", allowed: ["style", "goal"])
    case _?:
      fail("chart", .invalidType, "chart must be an object.")
    }

    unknownFields(
      input, path: "",
      allowed: ["version", "display", "series", "formulas", "bucket", "range", "chart"])

    // Defaults from the first visible series' type, or the first series' when every one is
    // hidden: the line the card draws, so a default never fails a rule.
    let first = series.first { !$0.hidden } ?? series.first
    if style == nil, !styleIsExplicit, let type = first?.type, let typeStyle = type.chartStyle {
      // A count has no lowest and highest reading to draw.
      style = typeStyle == .ranges && first?.aggregation == .count ? .dots : typeStyle
    }
    let category = first?.type?.category
    // A value that was wrong has its error already, so no spec comes of the default.
    if symbol == nil { symbol = category?.symbolName }
    if color == nil { color = category.flatMap { CardColor(rawValue: $0.colorName) } }

    // Second pass
    checkAcross(
      series: series, formulas: formulas,
      seriesCountIsValid: seriesCountIsValid, formulaCountIsValid: formulaCountIsValid,
      bucket: bucket, range: rangeIsExplicit ? range : nil, style: style, unit: unit,
      goal: hasGoal ? goal : nil)

    guard errors.isEmpty, let name, let symbol, let color, let bucket, let range, let style
    else { return nil }
    return CardSpec(
      version: HealthCards.specVersion,
      display: CardSpec.Display(name: name, symbol: symbol, color: color, unit: unit),
      series: series.map {
        CardSpec.Series(
          id: $0.id!, type: $0.type!.id, aggregation: $0.aggregation!, window: $0.window,
          filter: $0.filter, label: $0.label, hidden: $0.hidden)
      },
      formulas: formulas.map { formula in
        let operation: CardSpec.Formula.Operation =
          switch formula.kind! {
          case .movingAverage: .movingAverage(of: formula.of![0], points: formula.points!)
          case .difference: .difference(of: formula.of![0], minus: formula.of![1])
          }
        return CardSpec.Formula(
          id: formula.id!, operation: operation, label: formula.label, hidden: formula.hidden)
      },
      bucket: bucket,
      range: range,
      chart: CardSpec.Chart(style: style, goal: goal.flatMap { $0.number }.map(CardSpec.Goal.init))
    )
  }

  private mutating func parseSeries(_ item: CardJSON, index: Int) -> Series {
    let path = "series[\(index)]"
    var series = Series(path: path)
    guard case .object = item else {
      fail(
        path, .invalidType,
        "\(path) must be an object, e.g. {\"type\": \"HKQuantityTypeIdentifierHeartRate\"}.")
      return series
    }

    series.id = id(item["id"], path: "\(path).id", default: Self.seriesID(index))

    switch item["type"] {
    case nil, .null?:
      fail(
        "\(path).type", .required,
        "\(path).type is required: a quantity type, e.g. HKQuantityTypeIdentifierHeartRate or "
          + "\"Heart Rate\".")
    case .string(let name)?:
      series.type = type(named: name, path: "\(path).type")
    case _?:
      fail(
        "\(path).type", .invalidType, "\(path).type must be a string: a type's identifier or name.")
    }
    let type = series.type

    switch item["aggregation"] {
    case nil, .null?:
      series.aggregation = type?.aggregation.map(CardSpec.Aggregation.defaultValue)
    case .string(let text)?:
      guard let aggregation = CardSpec.Aggregation(rawValue: text) else {
        fail(
          "\(path).aggregation", .unknownValue,
          "\(CardJSON.quoted(text)) isn't an aggregation. Use "
            + "\(Self.list(CardSpec.Aggregation.allCases.map(\.rawValue))).")
        break
      }
      if let type, let typeAggregation = type.aggregation,
        !CardSpec.Aggregation.allowed(for: typeAggregation).contains(aggregation)
      {
        fail(
          "\(path).aggregation", .aggregationNotAllowed,
          typeAggregation.isCumulative
            ? "\(type.name) adds up, so it takes \"sum\" only (avg, min, max, first, latest and count are "
              + "for types measured at points in time). For an average day over weeks or months, "
              + "use bucket \"auto\" at 6M or Y."
            : "\(type.name) doesn't add up: use avg, min, max, first, latest or count, not sum.")
      } else {
        series.aggregation = aggregation
      }
    case _?:
      fail("\(path).aggregation", .invalidType, "\(path).aggregation must be a string.")
    }

    let cumulativeName = type?.aggregation?.isCumulative == true ? type?.name : nil
    switch item["window"] {
    case nil, .null?: break
    case .object(let members)?:
      series.hasWindow = true
      if let cumulativeName {
        fail(
          "\(path).window", .windowOnCumulative,
          "Windows work with types measured at points in time (heart rate, HRV), not ones that "
            + "add up (\(cumulativeName)), in this version.")
      }
      (series.window, series.windowKind) = window(.object(members), path: "\(path).window")
    case _?:
      fail(
        "\(path).window", .invalidType,
        "\(path).window must be an object, e.g. {\"kind\": \"asleep\"}, or null.")
    }

    switch item["filter"] {
    case nil, .null?: break
    case .object(let members)?:
      if let cumulativeName {
        fail(
          "\(path).filter", .filterOnCumulative,
          "Filters work with types measured at points in time, not \(cumulativeName), which uses "
            + "Health's de-duplicated totals.")
      }
      series.filter = filter(.object(members), path: "\(path).filter")
    case _?:
      fail(
        "\(path).filter", .invalidType,
        "\(path).filter must be an object, e.g. {\"deviceModels\": [\"Watch\"]}, or null.")
    }

    series.label = label(item["label"], path: "\(path).label")
    series.hidden = hidden(item["hidden"], path: "\(path).hidden")
    unknownFields(
      item, path: path,
      allowed: ["id", "type", "aggregation", "window", "filter", "label", "hidden"])
    return series
  }

  private mutating func type(named name: String, path: String) -> HealthDataType? {
    guard let type = HealthCatalog.type(named: name) else {
      let suggestion = Self.typeClose(to: name).map {
        " Did you mean \($0.name) (\($0.id))?"
      }
      fail(
        path, .unknownType,
        "\(CardJSON.quoted(name)) isn't a type lil health knows.\(suggestion ?? "") list_types "
          + "lists them.")
      return nil
    }
    guard type.kind == .quantity else {
      let hint =
        switch type.kind {
        case _ where type.id == "HKCategoryTypeIdentifierSleepAnalysis":
          " To chart around sleep, use a window on a quantity, e.g. {\"kind\": \"asleep\"}."
        case .workout:
          " To chart during workouts, use a window on a quantity, e.g. {\"kind\": \"workout\"}."
        default: ""
        }
      fail(
        path, .notQuantity,
        "\(type.name) isn't a quantity: cards chart quantities such as heart rate or steps.\(hint)")
      return nil
    }
    guard HealthCards.isChartable(type) else {
      fail(
        path, .unreadableType,
        "\(type.name) can't be read from Health by apps, so cards can't chart it.")
      return nil
    }
    return type
  }

  /// The chartable type a mistyped name most likely meant: of those `search` would find for it
  /// (each of its words in the type's name, category or short identifier), the one with the
  /// shortest name, ties in the catalog's order. None for fewer than 3 letters.
  static func typeClose(to name: String) -> HealthDataType? {
    let words = name.lowercased().split(whereSeparator: \.isWhitespace)
    // A letter or two matches too much to mean anything.
    guard words.joined().count >= 3 else { return nil }
    return HealthCards.chartableTypes
      .filter { type in
        let text = "\(type.name) \(type.category?.name ?? "") \(HealthCatalog.shortID(type.id))"
          .lowercased()
        return words.allSatisfy { text.contains($0) }
      }
      .enumerated()
      .min { ($0.element.name.count, $0.offset) < ($1.element.name.count, $1.offset) }?
      .element
  }

  private mutating func window(
    _ json: CardJSON, path: String
  ) -> (CardSpec.Window?, CardSpec.Window.Kind?) {
    var kind: CardSpec.Window.Kind?
    switch json["kind"] {
    case nil, .null?:
      fail("\(path).kind", .required, "\(path).kind is required: \(Self.list(Self.windowKinds)).")
    case .string(let text)?:
      kind = CardSpec.Window.Kind(rawValue: text)
      if kind == nil {
        fail(
          "\(path).kind", .unknownValue,
          "\(CardJSON.quoted(text)) isn't a window. Use \(Self.list(Self.windowKinds)).")
      }
    case _?:
      fail("\(path).kind", .invalidType, "\(path).kind must be a string.")
    }

    var window: CardSpec.Window?
    let allowed: [String]
    switch kind {
    case .asleep:
      window = .asleep
      allowed = ["kind"]
    case .beforeSleep, .afterWaking:
      allowed = ["kind", "minutes"]
      let event = kind == .beforeSleep ? "before falling asleep" : "after waking"
      switch json["minutes"] {
      case nil, .null?:
        fail(
          "\(path).minutes", .required,
          "\(path).minutes is required: how many minutes \(event), from 1 to 240.")
      case .number(let minutes)? where Self.isWhole(minutes, in: HealthCards.windowMinutes):
        window =
          kind == .beforeSleep
          ? .beforeSleep(minutes: Int(minutes)) : .afterWaking(minutes: Int(minutes))
      case _?:
        fail(
          "\(path).minutes", .windowMinutes, "\(path).minutes must be a whole number from 1 to 240."
        )
      }
    case .workout:
      allowed = ["kind", "activities"]
      switch json["activities"] {
      case nil, .null?: window = .workout(activities: nil)
      case .array(let items)?:
        if let activities = activities(items, path: "\(path).activities") {
          window = .workout(activities: activities)
        }
      case _?:
        fail(
          "\(path).activities", .invalidType,
          "\(path).activities must be an array of workout activities, or null for every workout.")
      }
    case .timeOfDay:
      allowed = ["kind", "from", "to"]
      func time(_ key: String, _ what: String) -> CardClockTime? {
        let timePath = "\(path).\(key)"
        switch json[key] {
        case nil, .null?:
          fail(
            timePath, .required,
            "\(timePath) is required: \(what), on the 24-hour clock, e.g. \"\(key == "from" ? "07:30" : "12:00")\"."
          )
        case .string(let text)?:
          if let time = CardClockTime(text) { return time }
          fail(
            timePath, .windowTime,
            "\(timePath) must be a time on the 24-hour clock, \"HH:MM\" from \"00:00\" to "
              + "\"23:59\" (it's \(CardJSON.quoted(text))).")
        case let other?:
          fail(
            timePath, .windowTime,
            "\(timePath) must be a time on the 24-hour clock, \"HH:MM\" from \"00:00\" to "
              + "\"23:59\" (it's \(other.text())).")
        }
        return nil
      }
      let from = time("from", "when the window starts")
      let to = time("to", "when it ends")
      if let from, let to {
        if from == to {
          fail(
            path, .windowTime,
            "\(path) starts and ends at \(from): for every reading, set window to null. A window "
              + "may cross midnight, e.g. from \"22:00\" to \"06:00\".")
        } else {
          window = .timeOfDay(CardTimeOfDay(from: from, to: to))
        }
      }
    case nil:
      allowed = ["kind", "minutes", "activities", "from", "to"]
    }
    unknownFields(json, path: path, allowed: allowed)
    return (window, kind)
  }

  private mutating func activities(_ items: [CardJSON], path: String) -> [Int]? {
    let errorCount = errors.count
    if !HealthCards.windowActivities.contains(items.count) {
      fail(
        path, .activityCount,
        "\(path) must have 1 to 10 activities (it has \(items.count)), or be null for every workout."
      )
    }
    var activities: [Int] = []
    for (index, item) in items.enumerated() {
      let itemPath = "\(path)[\(index)]"
      var activity: Int?
      switch item {
      case .number(let value):
        if value == value.rounded(), abs(value) < 1e9,
          HealthCatalog.workoutActivityNames[Int(value)] != nil
        {
          activity = Int(value)
        }
      case .string(let name):
        activity =
          HealthCatalog.workoutActivityNames.first {
            $0.value.lowercased() == name.lowercased()
          }?.key
      default: break
      }
      guard let activity else {
        fail(
          itemPath, .unknownActivity,
          "\(item.text()) isn't a workout activity. Use HKWorkoutActivityType raw values or "
            + "names, e.g. 37 or \"Running\".")
        continue
      }
      if activities.contains(activity) {
        fail(
          itemPath, .duplicateActivity,
          "\(path) has \(HealthCatalog.workoutActivityName(activity)) twice.")
      }
      activities.append(activity)
    }
    return errors.count == errorCount ? activities : nil
  }

  private mutating func filter(_ json: CardJSON, path: String) -> CardSpec.Filter? {
    let errorCount = errors.count
    func list(_ key: String) -> [String]? {
      let listPath = "\(path).\(key)"
      switch json[key] {
      case nil, .null?: return nil
      case .array(let items)?:
        if !HealthCards.filterListLength.contains(items.count) {
          fail(
            listPath, .filterList,
            "\(listPath) must have 1 to 10 entries (it has \(items.count)), or be null.")
        }
        return items.enumerated().compactMap { index, item in
          guard case .string(let text) = item,
            HealthCards.filterValueLength.contains(text.unicodeScalars.count)
          else {
            fail(
              "\(listPath)[\(index)]", .filterValue,
              "\(listPath)[\(index)] must be a string of 1 to 200 characters.")
            return nil
          }
          return text
        }
      case _?:
        fail(listPath, .invalidType, "\(listPath) must be an array of strings, or null.")
        return nil
      }
    }
    let sources = list("sources")
    let deviceModels = list("deviceModels")
    if json["sources"].isAbsent, json["deviceModels"].isAbsent {
      fail(
        path, .emptyFilter,
        "A filter needs sources or deviceModels. For every source, set filter to null.")
    }
    unknownFields(json, path: path, allowed: ["sources", "deviceModels"])
    return errors.count == errorCount
      ? CardSpec.Filter(sources: sources, deviceModels: deviceModels) : nil
  }

  private mutating func parseFormula(_ item: CardJSON, index: Int) -> Formula {
    let path = "formulas[\(index)]"
    var formula = Formula(path: path)
    guard case .object = item else {
      fail(
        path, .invalidType,
        "\(path) must be an object, e.g. {\"kind\": \"movingAverage\", \"of\": \"a\", \"points\": 7}."
      )
      return formula
    }
    formula.id = id(item["id"], path: "\(path).id", default: "f\(index + 1)")

    switch item["kind"] {
    case nil, .null?:
      fail("\(path).kind", .required, "\(path).kind is required: movingAverage or difference.")
    case .string(let text)?:
      formula.kind = CardSpec.Formula.Kind(rawValue: text)
      if formula.kind == nil {
        fail(
          "\(path).kind", .unknownValue,
          "\(CardJSON.quoted(text)) isn't a formula. Use movingAverage or difference.")
      }
    case _?:
      fail("\(path).kind", .invalidType, "\(path).kind must be a string.")
    }

    let allowed: [String]
    switch formula.kind {
    case .movingAverage:
      allowed = ["id", "kind", "of", "points", "label", "hidden"]
      switch item["of"] {
      case nil, .null?:
        fail(
          "\(path).of", .required,
          "\(path).of is required: the id of the series it averages, e.g. \"a\".")
      case .string(let id)?: formula.of = [id]
      case _?: fail("\(path).of", .invalidType, "\(path).of must be a series' id, e.g. \"a\".")
      }
      switch item["points"] {
      case nil, .null?: formula.points = 7
      case .number(let points)? where Self.isWhole(points, in: HealthCards.movingAveragePoints):
        formula.points = Int(points)
      case _?:
        fail(
          "\(path).points", .formulaPoints, "\(path).points must be a whole number from 2 to 30.")
      }
    case .difference:
      allowed = ["id", "kind", "of", "label", "hidden"]
      switch item["of"] {
      case nil, .null?:
        fail(
          "\(path).of", .required,
          "\(path).of is required: the ids of the two series it subtracts, e.g. [\"a\", \"b\"].")
      case let of?:
        let ids: [String] =
          if case .array(let items) = of {
            items.compactMap { item in
              if case .string(let id) = item { id } else { nil }
            }
          } else { [] }
        if ids.count == 2, of == .array(ids.map(CardJSON.string)) {
          formula.of = ids
        } else {
          fail(
            "\(path).of", .invalidType,
            "\(path).of must be two series' ids, e.g. [\"a\", \"b\"]: the first minus the second.")
        }
      }
    case nil:
      allowed = ["id", "kind", "of", "points", "label", "hidden"]
    }

    formula.label = label(item["label"], path: "\(path).label")
    formula.hidden = hidden(item["hidden"], path: "\(path).hidden")
    unknownFields(item, path: path, allowed: allowed)
    return formula
  }

  // MARK: - Fields

  private mutating func id(_ json: CardJSON?, path: String, default: String) -> String? {
    switch json {
    case nil, .null?: return `default`
    case .string(let id)?:
      guard Self.isValidID(id) else {
        fail(
          path, .invalidID,
          "\(path) must be a lowercase letter, then up to 15 lowercase letters or digits, e.g. "
            + "\"a\" or \"trend\" (it's \(CardJSON.quoted(id))).")
        return nil
      }
      return id
    case _?:
      fail(path, .invalidType, "\(path) must be a string, e.g. \"a\".")
      return nil
    }
  }

  /// `^[a-z][a-z0-9]{0,15}$`
  static func isValidID(_ id: String) -> Bool {
    let scalars = Array(id.unicodeScalars)
    guard let first = scalars.first, ("a"..."z").contains(first), scalars.count <= 16 else {
      return false
    }
    return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
  }

  /// A name or label: trimmed, 1 to 40 code points, no line breaks or control characters.
  private mutating func text(
    _ text: String, path: String, code: Code, orNull: Bool
  ) -> String? {
    let trimmed = HealthCards.trimmed(text)
    let length = trimmed.unicodeScalars.count
    guard HealthCards.textLength.contains(length) else {
      fail(
        path, code,
        "\(path) must be 1 to 40 characters (it's \(length))\(orNull ? ", or null" : "").")
      return nil
    }
    guard !trimmed.unicodeScalars.contains(where: HealthCards.isForbidden) else {
      fail(path, .invalidCharacters, "\(path) can't have line breaks or control characters.")
      return nil
    }
    return trimmed
  }

  private mutating func label(_ json: CardJSON?, path: String) -> String? {
    switch json {
    case nil, .null?: return nil
    case .string(let label)?: return text(label, path: path, code: .labelLength, orNull: true)
    case _?:
      fail(path, .invalidType, "\(path) must be a string or null.")
      return nil
    }
  }

  private mutating func hidden(_ json: CardJSON?, path: String) -> Bool {
    switch json {
    case nil, .null?: return false
    case .bool(let hidden)?: return hidden
    case _?:
      fail(path, .invalidType, "\(path) must be true or false.")
      return false
    }
  }

  private mutating func unknownFields(_ json: CardJSON, path: String, allowed: [String]) {
    guard case .object(let members) = json else { return }
    let unknown = members.map(\.key).filter { !allowed.contains($0) }
      .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    for key in unknown {
      fail(
        path.isEmpty ? key : "\(path).\(key)", .unknownField,
        "Unknown field \(CardJSON.quoted(key)) in \(path.isEmpty ? "the spec" : path). Allowed: "
          + "\(allowed.joined(separator: ", ")).")
    }
  }

  // MARK: - Second pass

  private mutating func checkAcross(
    series: [Series], formulas: [Formula], seriesCountIsValid: Bool, formulaCountIsValid: Bool,
    bucket: CardSpec.Bucket?, range: CardRange?, style: HealthDataType.ChartStyle?,
    unit: String?, goal: CardJSON?
  ) {
    // IDs
    var seen: [String: Bool] = [:]  // id: whether it's a series'
    for (path, id, isSeries) in series.map({ ("\($0.path).id", $0.id, true) })
      + formulas.map({ ("\($0.path).id", $0.id, false) })
    {
      guard let id else { continue }
      if let wasSeries = seen[id] {
        fail(
          path, .duplicateID,
          "\(CardJSON.quoted(id)) is already a \(wasSeries ? "series'" : "formula's") id. Each "
            + "series and formula needs its own.")
      } else {
        seen[id] = isSeries
      }
    }

    // References
    let seriesByID = Dictionary(
      series.compactMap { item in item.id.map { ($0, item) } },
      uniquingKeysWith: { first, _ in first })
    let formulaIDs = Set(formulas.compactMap(\.id))
    var formulaUnits: [CardValueUnit?] = []
    for formula in formulas {
      guard let of = formula.of else {
        formulaUnits.append(nil)
        continue
      }
      var resolved: [Series] = []
      for id in of {
        if let item = seriesByID[id] {
          resolved.append(item)
        } else {
          let note = formulaIDs.contains(id) ? " Formulas take series only." : ""
          fail(
            "\(formula.path).of", .unknownReference,
            "\(formula.path) refers to \(CardJSON.quoted(id)), which isn't a series of this card.\(note)"
          )
        }
      }
      if formula.kind == .difference, of.count == 2, of[0] == of[1] {
        fail(
          "\(formula.path).of", .sameSeries,
          "\(formula.path) subtracts \(CardJSON.quoted(of[0])) from itself: name two different "
            + "series.")
      } else if formula.kind == .difference, resolved.count == 2,
        let a = resolved[0].unit, let b = resolved[1].unit, a != b
      {
        fail(
          "\(formula.path).of", .mixedUnits,
          "\(formula.path) subtracts \(Self.describe(resolved[1])) from "
            + "\(Self.describe(resolved[0])): both need the same unit.")
      }
      formulaUnits.append(resolved.count == of.count ? resolved.first?.unit : nil)
    }

    // One axis
    enum Line {
      case series(Series)
      case formula(Formula, CardValueUnit?)
    }
    let visible: [Line] =
      series.filter { !$0.hidden }.map(Line.series)
      + zip(formulas, formulaUnits).filter { !$0.0.hidden }.map { Line.formula($0.0, $0.1) }
    func lineUnit(_ line: Line) -> CardValueUnit? {
      switch line {
      case .series(let series): series.unit
      case .formula(_, let unit): unit
      }
    }
    func describe(_ line: Line) -> String {
      switch line {
      case .series(let series): Self.describe(series)
      case .formula(let formula, let unit):
        "\(formula.path) (\(unit == .readings ? "a count of readings" : unit?.description ?? ""))"
      }
    }
    let lead = visible.first
    if let lead, let leadUnit = lineUnit(lead) {
      for line in visible.dropFirst() {
        guard let otherUnit = lineUnit(line), otherUnit != leadUnit else { continue }
        let path =
          switch line {
          case .series(let series): "\(series.path).type"
          case .formula(let formula, _): "\(formula.path).of"
          }
        fail(
          path, .mixedUnits,
          "\(Self.capitalized(describe(line))) can't share a card with \(describe(lead)): a card "
            + "has one axis. Make it a card of its own.")
      }
    }

    // Visible lines
    if !series.isEmpty, visible.isEmpty {
      fail(
        "series", .nothingVisible, "Every series and formula is hidden: leave at least one visible."
      )
    }
    if seriesCountIsValid, formulaCountIsValid, visible.count > HealthCards.maxVisibleLines {
      fail(
        "formulas", .visibleCount,
        "A card shows at most 4 lines (series and formulas); this one has \(visible.count).")
    }

    // Buckets
    let sleepWindows = series.contains { $0.windowKind?.isSleep ?? false }
    let unknownWindows = series.contains { $0.hasWindow && $0.windowKind == nil }
    if bucket == .night, !sleepWindows, !unknownWindows {
      fail(
        "bucket", .nightNeedsSleepWindow,
        "bucket \"night\" needs a series with a sleep window: {\"kind\": \"asleep\"}, "
          + "\"beforeSleep\" or \"afterWaking\".")
    }
    if let bucket, sleepWindows, [.auto, .hour, .day].contains(bucket) {
      fail(
        "bucket", .sleepWindowBucket,
        "Sleep windows need bucket \"night\", \"week\" or \"month\": an hour or a calendar day "
          + "would cut nights in two.")
    }
    if let bucket, let range, !bucket.ranges.contains(range) {
      fail(
        "range", .rangeNotForBucket,
        "range \(CardJSON.quoted(range.rawValue)) doesn't fit bucket "
          + "\(CardJSON.quoted(bucket.rawValue)) (\(Self.points(bucket, range))). Ranges for "
          + "\(CardJSON.quoted(bucket.rawValue)): "
          + "\(bucket.ranges.map(\.rawValue).joined(separator: ", ")).")
    }

    // Chart style
    if style == .ranges,
      let total = visible.lazy.compactMap({ line -> Series? in
        guard case .series(let series) = line,
          series.aggregation == .sum || series.aggregation == .count
        else { return nil }
        return series
      }).first
    {
      let what =
        total.aggregation == .sum
        ? "\(total.type?.name ?? "it") is a total"
        : "\(Self.describe(total)) has none"
      fail(
        "chart.style", .rangesStyle,
        "\"ranges\" draws each bucket's lowest and highest reading, and \(what). Use bars, dots or "
          + "line.")
    }

    // Display unit
    if let unit, let lead, let leadUnit = lineUnit(lead) {
      let dimension: CardDisplayUnit.Dimension? =
        switch leadUnit {
        case .catalog(let catalogUnit): CardDisplayUnit.dimension(ofCatalogUnit: catalogUnit)
        case .readings: nil
        }
      if let dimension {
        if !dimension.units.contains(unit) {
          fail(
            "display.unit", .unitDimension,
            "\(CardJSON.quoted(unit)) isn't a unit for \(describe(lead)). Use "
              + "\(Self.list(dimension.units)), or null for the locale's.")
        }
      } else {
        fail(
          "display.unit", .unitDimension,
          "\(CardJSON.quoted(unit)) isn't a unit for \(describe(lead)), which has no others: use "
            + "null.")
      }
    }

    // Goal
    if let goal {
      let isValid =
        if case .number(let value) = goal { value >= 0 && value.isFinite } else { false }
      if !isValid {
        let unit: String =
          switch lead {
          case nil: ""
          case .series(let series)?:
            switch series.unit {
            case nil: ""
            case .readings?: ", in readings (\(Self.describe(series)))"
            case .catalog(let unit)?: ", in \(unit) (\(series.type?.name ?? "")'s unit)"
            }
          case .formula(let formula, let unit)?:
            unit.map {
              ", in \($0 == .readings ? "readings" : $0.description) (\(formula.path)'s unit)"
            }
              ?? ""
          }
        fail(
          "chart.goal.value", .goalValue, "chart.goal.value must be a number of at least 0\(unit).")
      }
    }
  }

  // MARK: - Messages

  static let styles = HealthDataType.ChartStyle.allCases.map(\.rawValue)
  static let windowKinds = CardSpec.Window.Kind.allCases.map(\.rawValue)

  static func seriesID(_ index: Int) -> String {
    String(UnicodeScalar(UInt8(ascii: "a") + UInt8(min(index, 25))))
  }

  static func isWhole(_ value: Double, in range: ClosedRange<Int>) -> Bool {
    value == value.rounded() && value >= Double(range.lowerBound)
      && value <= Double(range.upperBound)
  }

  /// "a, b or c"
  static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " or " + items.last!
  }

  /// A description at the start of a sentence: "A count of …". Paths stay as they are.
  static func capitalized(_ text: String) -> String {
    text.hasPrefix("a count") ? "A" + text.dropFirst() : text
  }

  /// "Heart Rate (count/min)", or "a count of Heart Rate readings".
  private static func describe(_ series: Series) -> String {
    let name = series.type?.name ?? series.path
    if series.aggregation == .count { return "a count of \(name) readings" }
    return "\(name) (\(series.type?.unit ?? ""))"
  }

  /// How many points a range would have in a bucket that doesn't offer it.
  static func points(_ bucket: CardSpec.Bucket, _ range: CardRange) -> String {
    switch (bucket, range) {
    case (.hour, .month): "up to 744 points"
    case (.hour, .sixMonths): "up to 4,416 points"
    case (.hour, .year): "up to 8,784 points"
    default: "1 point"
    }
  }
}

extension CardJSON {
  fileprivate var number: Double? {
    if case .number(let value) = self { value } else { nil }
  }
}

extension CardJSON? {
  /// Left out, or null: a field with a default takes it.
  fileprivate var isAbsent: Bool {
    switch self {
    case nil, .null?: true
    default: false
    }
  }
}
