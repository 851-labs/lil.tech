public import Foundation

/// A card run over one period: what its page and Summary row draw, and the tools return
/// (docs/decisions/cards.md, Inputs and outputs). Values are in each series' catalog unit; the apps
/// convert them for display (`MetricFormat`).
public struct CardData: Equatable, Sendable {
  /// The range it was run for, or `nil` for a headline's buckets.
  public var range: CardRange?
  /// The period: only readings in it count.
  public var interval: DateInterval
  /// The spec's bucket, and what each point covers.
  public var bucket: CardSpec.Bucket
  public var grain: CardGrain
  public var series: [Series]
  public var formulas: [Formula]
  /// What the page's header shows; `nil` when the period has no data (No Data).
  public var summary: CardSummary?
  /// The goal's value, in the lead's value unit.
  public var goal: Double?

  public init(
    range: CardRange?, interval: DateInterval, bucket: CardSpec.Bucket, grain: CardGrain,
    series: [Series], formulas: [Formula], summary: CardSummary?, goal: Double?
  ) {
    self.range = range
    self.interval = interval
    self.bucket = bucket
    self.grain = grain
    self.series = series
    self.formulas = formulas
    self.summary = summary
    self.goal = goal
  }

  public struct Series: Equatable, Identifiable, Sendable {
    public var id: String
    /// The series' label, or its type's name.
    public var label: String
    public var type: String
    public var aggregation: CardSpec.Aggregation
    public var unit: CardValueUnit
    public var hidden: Bool
    /// One a bucket with a value, in order.
    public var points: [CardPoint]

    public init(
      id: String, label: String, type: String, aggregation: CardSpec.Aggregation,
      unit: CardValueUnit, hidden: Bool, points: [CardPoint]
    ) {
      self.id = id
      self.label = label
      self.type = type
      self.aggregation = aggregation
      self.unit = unit
      self.hidden = hidden
      self.points = points
    }
  }

  public struct Formula: Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: CardSpec.Formula.Kind
    /// The formula's label, if it has one.
    public var label: String?
    public var unit: CardValueUnit
    public var hidden: Bool
    public var points: [CardFormulaPoint]

    public init(
      id: String, kind: CardSpec.Formula.Kind, label: String?, unit: CardValueUnit, hidden: Bool,
      points: [CardFormulaPoint]
    ) {
      self.id = id
      self.kind = kind
      self.label = label
      self.unit = unit
      self.hidden = hidden
      self.points = points
    }
  }

  /// The lead's points, as `(start, value)`: its first visible series', or with every series
  /// hidden, its first visible formula's.
  public var leadPoints: [CardFormulaPoint] {
    if let series = series.first(where: { !$0.hidden }) {
      return series.points.map { CardFormulaPoint(start: $0.start, value: $0.value) }
    }
    return formulas.first { !$0.hidden }?.points ?? []
  }
}

/// One bucket of a series.
public struct CardPoint: Equatable, Sendable {
  /// The bucket's start.
  public var start: Date
  /// By the series' aggregation: the total, the weighted average, the lowest or highest reading,
  /// the first or latest, or how many there were.
  public var value: Double
  /// The bucket's lowest and highest readings. Both are `value` for totals and counts, whose
  /// values aren't readings.
  public var minimum: Double
  public var maximum: Double
  /// How many readings it has; `nil` for totals.
  public var readings: Int?

  public init(
    start: Date, value: Double, minimum: Double? = nil, maximum: Double? = nil,
    readings: Int? = nil
  ) {
    self.start = start
    self.value = value
    self.minimum = minimum ?? value
    self.maximum = maximum ?? value
    self.readings = readings
  }
}

/// One bucket of a formula.
public struct CardFormulaPoint: Equatable, Sendable {
  public var start: Date
  public var value: Double

  public init(start: Date, value: Double) {
    self.start = start
    self.value = value
  }
}

/// What the page's header shows for the period, from the lead (docs/decisions/cards.md, Summary
/// and headline).
public struct CardSummary: Equatable, Sendable {
  public var kind: Kind
  /// `nil` for a range.
  public var value: Double?
  /// A range's lowest and highest readings; `nil` otherwise.
  public var minimum: Double?
  public var maximum: Double?

  public init(kind: Kind, value: Double?, minimum: Double? = nil, maximum: Double? = nil) {
    self.kind = kind
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
  }

  public enum Kind: String, CaseIterable, Hashable, Sendable {
    /// A day's total, or a fixed bucket's when the period is one bucket.
    case total
    /// The average of the period's readings, or a total's average day (or bucket) with data, or
    /// of a formula's points.
    case average
    /// A total's average day at 6M or Y, captioned DAILY AVERAGE.
    case dailyAverage
    /// The lowest and highest reading, for `avg` drawn as `ranges`.
    case range
    case lowest
    case highest
    case first
    case latest
    case count
  }
}
