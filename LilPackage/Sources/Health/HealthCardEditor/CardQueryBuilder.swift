import Foundation
public import HealthCards
public import HealthCatalog

// The query builder's rules (851-3209, docs/decisions/cards.md, UI › Mac): what each field offers
// given the rest of the draft, what a change does to the fields it rules out, and which field a
// validation error is about.

extension CardEditorFeature.State {
  // MARK: - Changes

  /// A series' type. A new card's first series' type gives the card its name, symbol and color
  /// until the person changes them; its style follows the card's first visible series' type
  /// until it's chosen (`input`).
  mutating func typeChosen(_ typeID: String, series id: String) {
    guard let index = draft.series.firstIndex(where: { $0.id == id }),
      let type = HealthCatalog.type(id: typeID)
    else { return }
    draft.series[index].type = typeID
    if isNew, index == 0 {
      if !isNameEdited { name = type.name }
      if !isSymbolChosen { symbol = type.category?.symbolName ?? Self.newCardSymbol }
      if !isColorChosen {
        color = type.category.flatMap { CardColor(rawValue: $0.colorName) } ?? Self.newCardColor
      }
    }
    normalize()
  }

  /// Another series, of the first's type and aggregation, so it fits the card's axis.
  mutating func addSeries() {
    guard canAddSeries, let first = draft.series.first else { return }
    draft.series.append(
      CardSpec.Series(
        id: unusedID(among: "abcd".map(String.init)), type: first.type,
        aggregation: first.aggregation))
    normalize()
  }

  /// Removes a series, and the formulas computed from it.
  mutating func removeSeries(id: String) {
    guard draft.series.count > 1 else { return }
    draft.series.removeAll { $0.id == id }
    normalize()
  }

  /// A moving average of the first series over 7 points, or the difference of the first two.
  mutating func addFormula(_ kind: CardSpec.Formula.Kind) {
    guard canAddFormula(kind) else { return }
    let ids = draft.series.map(\.id)
    switch kind {
    case .movingAverage:
      draft.formulas.append(
        CardSpec.Formula(
          id: unusedID(among: ["trend", "trend2"]), operation: .movingAverage(of: ids[0], points: 7)
        ))
    case .difference:
      guard let (minuend, subtrahend) = differencePair else { return }
      draft.formulas.append(
        CardSpec.Formula(
          id: unusedID(among: ["gap", "gap2"]),
          operation: .difference(of: minuend, minus: subtrahend)))
    }
  }

  /// The first of `candidates` no series or formula has.
  private func unusedID(among candidates: [String]) -> String {
    let used = Set(draft.series.map(\.id) + draft.formulas.map(\.id))
    return candidates.first { !used.contains($0) } ?? "x\(used.count)"
  }

  /// Makes every field one the rules allow, given the others: a type's aggregation, no window or
  /// filter for totals, formulas of series that are there, a bucket for the windows, a range for
  /// the bucket, a style for the aggregations and a unit for the lead.
  mutating func normalize() {
    for index in draft.series.indices {
      guard let aggregation = draft.series[index].dataType?.aggregation else { continue }
      if !CardSpec.Aggregation.allowed(for: aggregation).contains(draft.series[index].aggregation) {
        draft.series[index].aggregation = .defaultValue(for: aggregation)
      }
      if aggregation.isCumulative {
        draft.series[index].window = nil
        draft.series[index].filter = nil
      }
    }
    let ids = Set(draft.series.map(\.id))
    draft.formulas.removeAll { !$0.operation.seriesIDs.allSatisfy(ids.contains) }
    if !buckets.contains(draft.bucket) {
      draft.bucket = hasSleepWindow ? .night : .auto
    }
    if !draft.bucket.ranges.contains(draft.range) {
      draft.range = draft.bucket.defaultRange
    }
    if !styles.contains(draft.chart.style) {
      draft.chart.style =
        draft.series.contains { !$0.hidden && $0.aggregation == .sum }
        ? .bars : .dots
    }
    if let unit = draft.display.unit, !units.contains(unit) {
      draft.display.unit = nil
    }
    // A card's only line has no Show in Chart to turn it back on.
    if !hasSeveralLines {
      for index in draft.series.indices { draft.series[index].hidden = false }
      for index in draft.formulas.indices { draft.formulas[index].hidden = false }
    }
    // A goal is a number in the lead's unit: another unit makes it another goal.
    if draft.valueUnit != goalUnit {
      draft.chart.goal = nil
      goalUnit = draft.valueUnit
    }
  }

  // MARK: - What's offered

  /// Another series fits: fewer than 4, and fewer than 4 visible lines, since it's added visible.
  public var canAddSeries: Bool {
    !needsType && draft.series.count < HealthCards.maxSeries
      && visibleLineCount < HealthCards.maxVisibleLines
  }

  public func canAddFormula(_ kind: CardSpec.Formula.Kind) -> Bool {
    guard !needsType, draft.formulas.count < HealthCards.maxFormulas,
      visibleLineCount < HealthCards.maxVisibleLines
    else { return false }
    return kind == .movingAverage || differencePair != nil
  }

  /// The first two series a difference can subtract: the first pair in one unit.
  private var differencePair: (String, String)? {
    for (index, first) in draft.series.enumerated() {
      if let second = draft.series[(index + 1)...].first(where: { $0.valueUnit == first.valueUnit })
      {
        return (first.id, second.id)
      }
    }
    return nil
  }

  private var visibleLineCount: Int {
    draft.series.count(where: { !$0.hidden }) + draft.formulas.count(where: { !$0.hidden })
  }

  /// Whether the card shows more than one line, so its lines have labels in a legend and can be
  /// hidden.
  public var hasSeveralLines: Bool { draft.series.count + draft.formulas.count > 1 }

  /// The types a series can chart: any chartable type for a card's only series, else those in
  /// the other series' unit, since a card has one axis.
  public func types(forSeries id: String) -> [HealthDataType] {
    let reference = draft.series.first { $0.id != id && !$0.type.isEmpty }?.dataType?.unit
    guard let reference else { return HealthCards.chartableTypes }
    return HealthCards.chartableTypes.filter { $0.unit == reference }
  }

  /// A series' aggregations: Total for a type that adds up, the others for the rest.
  public func aggregations(for series: CardSpec.Series) -> [CardSpec.Aggregation] {
    series.dataType?.aggregation.map(CardSpec.Aggregation.allowed(for:)) ?? []
  }

  var hasSleepWindow: Bool { draft.series.contains { $0.window?.isSleep ?? false } }

  /// Night, week and month with a sleep window, which a day would cut in two; the others
  /// without, since Night needs one.
  public var buckets: [CardSpec.Bucket] {
    hasSleepWindow ? [.night, .week, .month] : [.auto, .hour, .day, .week, .month]
  }

  /// Ranges, but not for a total or a count, which have no lowest and highest reading.
  public var styles: [HealthDataType.ChartStyle] {
    let hasNoRange = draft.series.contains {
      !$0.hidden && ($0.aggregation == .sum || $0.aggregation == .count)
    }
    return hasNoRange ? [.bars, .dots, .line] : HealthDataType.ChartStyle.allCases
  }

  /// The units the card may pin: its lead's dimension's, none for a count or a unit without
  /// others (`count/min`).
  public var units: [String] {
    guard case .catalog(let unit)? = draft.valueUnit,
      let dimension = CardDisplayUnit.dimension(ofCatalogUnit: unit)
    else { return [] }
    return dimension.units
  }

  /// The series a formula can be computed from: for a difference, those in the other operand's
  /// unit, but not the other operand itself.
  public func operands(excluding other: String? = nil) -> [CardSpec.Series] {
    let unit = other.flatMap { id in draft.series.first { $0.id == id } }?.valueUnit
    return draft.series.filter { $0.id != other && (unit == nil || $0.valueUnit == unit) }
  }

  // MARK: - Errors

  /// The errors about a field, as the editor words them: the validator's, which name the path
  /// for agents, with the field's name instead.
  public func errors(for field: Field) -> [String] {
    errors.filter { $0.field(in: draft) == field }.map(\.editorMessage)
  }
}

extension CardEditorFeature.State {
  /// What a spec's errors are about, in the editor's sections.
  public enum Field: Hashable, Sendable {
    case name, symbol, color
    /// A series' field, by the series' ID.
    case series(String, SeriesField)
    /// Every series: one visible, at most 4.
    case seriesList
    case formula(String, FormulaField)
    case formulaList
    case bucket, range, style, unit, goal
    /// The rest: the whole spec (its size).
    case query

    public enum SeriesField: Hashable, Sendable {
      case type, aggregation, window, filter, label, hidden
    }

    public enum FormulaField: Hashable, Sendable {
      case operands, points, label, hidden
    }
  }
}

extension CardSpecError {
  /// The editor's field the error is about, by its path.
  func field(in draft: CardSpec) -> CardEditorFeature.State.Field {
    switch path {
    case "display.name": return .name
    case "display.symbol": return .symbol
    case "display.color": return .color
    case "display.unit": return .unit
    case "series": return .seriesList
    case "formulas": return .formulaList
    case "bucket": return .bucket
    case "range": return .range
    case "chart.style": return .style
    case "chart.goal", "chart.goal.value": return .goal
    default: break
    }
    if let (index, rest) = Self.element(of: "series", in: path),
      draft.series.indices.contains(index)
    {
      let id = draft.series[index].id
      let field: CardEditorFeature.State.Field.SeriesField =
        switch rest.first {
        case "aggregation": .aggregation
        case "window": .window
        case "filter": .filter
        case "label": .label
        case "hidden": .hidden
        default: .type
        }
      return .series(id, field)
    }
    if let (index, rest) = Self.element(of: "formulas", in: path),
      draft.formulas.indices.contains(index)
    {
      let id = draft.formulas[index].id
      let field: CardEditorFeature.State.Field.FormulaField =
        switch rest.first {
        case "points": .points
        case "label": .label
        case "hidden": .hidden
        default: .operands
        }
      return .formula(id, field)
    }
    return .query
  }

  /// `series[2].window.minutes` as 2 and `["window", "minutes"]`.
  private static func element(of array: String, in path: String) -> (Int, [Substring])? {
    guard path.hasPrefix(array + "["), let close = path.firstIndex(of: "]") else { return nil }
    let start = path.index(path.startIndex, offsetBy: array.count + 1)
    guard let index = Int(path[start..<close]) else { return nil }
    let rest = path[path.index(after: close)...].split(separator: ".")
    return (index, rest)
  }

  /// The message as the editor shows it, under its field: the field's name rather than its path
  /// ("Name must be 1 to 40 characters"), and nothing about JSON's `null`.
  var editorMessage: String {
    if code == .windowTime, !path.hasSuffix(".from"), !path.hasSuffix(".to") {
      return "From and To can't be the same time. To can be earlier than From, to cross midnight."
    }
    var message = message
    let last = path.split(separator: ".").last.map(String.init) ?? ""
    let names = [
      "name": "Name", "symbol": "Symbol", "color": "Color", "unit": "Unit", "label": "Label",
      "minutes": "Minutes", "from": "From", "to": "To", "value": "Goal", "points": "Points",
    ]
    if let name = names[last], message.hasPrefix(path) {
      message = name + message.dropFirst(path.count)
    }
    if message.hasSuffix(", or null.") {
      message = message.dropLast(", or null.".count) + "."
    }
    return message
  }
}
