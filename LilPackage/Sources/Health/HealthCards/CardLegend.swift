import HealthCatalog

/// One line of a card's legend (docs/decisions/cards.md, UI › The legend): what a visible series
/// or formula is called, and how it's drawn.
public struct CardLegendLine: Hashable, Sendable {
  public enum Mark: Hashable, Sendable {
    /// A series, by its place among the visible series: the first is drawn in the card's color,
    /// the second at 60% opacity, the third and fourth at 40% and 25%, with dots of their own
    /// shapes (``CardSeriesMark``).
    case series(CardSeriesMark)
    /// A formula: a line in the card's color.
    case formula
  }

  public var mark: Mark
  public var label: String

  public init(mark: Mark, label: String) {
    self.mark = mark
    self.label = label
  }
}

/// How a visible series is drawn, by its place among the card's visible series, so one card stays
/// one color: its opacity, and its dots' shape.
public enum CardSeriesMark: Int, CaseIterable, Hashable, Sendable {
  case circle, square, triangle, diamond

  /// The mark of the visible series at `index`; the last for any past it.
  public init(index: Int) {
    self = Self.allCases[min(max(index, 0), Self.allCases.count - 1)]
  }

  public var opacity: Double {
    switch self {
    case .circle: 1
    case .square: 0.6
    case .triangle: 0.4
    case .diamond: 0.25
    }
  }
}

extension CardSpec {
  /// The legend: a line for each visible series and formula, in the spec's order (series, then
  /// formulas), or none for a card with one visible line, as Summary's rows had none. A series is
  /// its `label`, or else its type's name; a formula its `label`, or else what it computes
  /// ("7-point moving average", "7-point moving average of Heart Rate" with more than one series,
  /// "Heart Rate − Resting Heart Rate").
  public var legend: [CardLegendLine] {
    let visibleSeries = series.filter { !$0.hidden }
    let visibleFormulas = formulas.filter { !$0.hidden }
    guard visibleSeries.count + visibleFormulas.count > 1 else { return [] }
    return visibleSeries.enumerated().map { index, series in
      CardLegendLine(mark: .series(CardSeriesMark(index: index)), label: name(of: series))
    }
      + visibleFormulas.map { formula in
        CardLegendLine(mark: .formula, label: formula.label ?? description(of: formula))
      }
  }

  /// A series' label, or its type's name.
  public func name(of series: Series) -> String {
    series.label ?? series.dataType?.name ?? series.type
  }

  /// What a formula without a label computes, in words.
  public func description(of formula: Formula) -> String {
    func name(_ id: String) -> String {
      series.first { $0.id == id }.map { self.name(of: $0) } ?? id
    }
    switch formula.operation {
    case .movingAverage(let of, let points):
      // Of which series, when there's more than one to average.
      return series.count > 1
        ? "\(points)-point moving average of \(name(of))" : "\(points)-point moving average"
    case .difference(let minuend, let subtrahend):
      return "\(name(minuend)) − \(name(subtrahend))"
    }
  }
}
