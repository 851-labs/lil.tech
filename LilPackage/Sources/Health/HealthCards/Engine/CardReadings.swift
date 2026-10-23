public import Foundation
public import HealthCatalog

// Readings, their weights and aggregations (docs/decisions/cards.md, Readings and weights). Metric
// Detail's averages (`HealthDatabase.discreteStatistics`) use the same weights, so a card and the
// page agree to the bit.

/// One sample of a series' type with a value, as every engine reads it.
public struct CardReading: Hashable, Sendable {
  /// Unix milliseconds.
  public var start: Int
  public var end: Int
  /// In the type's catalog unit.
  public var value: Double
  /// The source's bundle ID: each source is its own series for time weighting.
  public var source: String
  /// The sample's ID (a lowercase UUID), for `first`'s and `latest`'s ties. Fetchers may leave it
  /// empty for other aggregations (`CardFetch.needsSampleIDs`).
  public var sampleID: String

  public init(start: Int, end: Int, value: Double, source: String, sampleID: String = "") {
    self.start = start
    self.end = end
    self.value = value
    self.source = source
    self.sampleID = sampleID
  }
}

/// A cumulative type's total over one bucket: Health's de-duplicated totals.
public struct CardTotal: Hashable, Sendable {
  public var start: Date
  public var sum: Double

  public init(start: Date, sum: Double) {
    self.start = start
    self.sum = sum
  }
}

/// A stretch of time a window keeps readings in, half-open, in Unix milliseconds.
public struct CardStretch: Hashable, Sendable {
  public var start: Int
  public var end: Int

  public init(start: Int, end: Int) {
    self.start = start
    self.end = end
  }
}

public enum CardWeights {
  /// The longest a reading counts for in a time-weighted average, in seconds.
  public static let maxSampleWeight: TimeInterval = 3600

  /// Each reading's weight in an average, in seconds, for readings oldest first:
  /// - Arithmetic: 1 each.
  /// - Time-weighted: until its source's next reading, or for its own duration if it's the
  ///   source's last, at least 1 s and at most an hour. Each source is its own series, so a
  ///   second device's readings don't cut one short.
  /// - Equivalent continuous level (sound): its duration, at least 1 s.
  public static func weights(
    of readings: [CardReading], _ aggregation: HealthDataType.Aggregation
  ) -> [Double] {
    switch aggregation {
    case .discreteTemporallyWeighted:
      var weights = [Double](repeating: 1, count: readings.count)
      var sources = CardSources()
      var nextStart: [Int?] = []
      for index in readings.indices.reversed() {
        let reading = readings[index]
        let source = sources.index(of: reading.source)
        if source == nextStart.count { nextStart.append(nil) }
        let until = nextStart[source] ?? reading.end
        weights[index] = min(max(Double(until - reading.start) / 1000, 1), maxSampleWeight)
        nextStart[source] = reading.start
      }
      return weights
    case .discreteEquivalentContinuousLevel:
      return readings.map { max(Double($0.end - $0.start) / 1000, 1) }
    case .cumulative, .discreteArithmetic:
      return readings.map { _ in 1 }
    }
  }

  /// Weights in a window, for readings oldest first, each with the index of the stretch it
  /// starts in. Time-weighted readings count until their source's next reading in the same
  /// stretch, or else the stretch's end, at least 1 s and at most an hour: each stretch is on its
  /// own, so a 5-minute window's lone reading counts 5 minutes. Other styles weigh as without a
  /// window.
  public static func weights(
    of readings: [CardReading], stretches: [CardStretch], stretchIndices: [Int],
    _ aggregation: HealthDataType.Aggregation
  ) -> [Double] {
    guard aggregation == .discreteTemporallyWeighted else {
      return weights(of: readings, aggregation)
    }
    var weights = [Double](repeating: 1, count: readings.count)
    var sources = CardSources()
    var next: [(stretch: Int, start: Int)?] = []
    for index in readings.indices.reversed() {
      let reading = readings[index]
      let stretch = stretchIndices[index]
      let source = sources.index(of: reading.source)
      if source == next.count { next.append(nil) }
      var until = stretches[stretch].end
      if let following = next[source], following.stretch == stretch {
        until = following.start
      }
      weights[index] = min(max(Double(until - reading.start) / 1000, 1), maxSampleWeight)
      next[source] = (stretch, reading.start)
    }
    return weights
  }

  /// The weighted average of `values`, by the type's aggregation style: an energy average
  /// (`10·log10(Σ w·10^(v/10) / Σ w)`) for sound levels, else arithmetic. 0 without weight.
  public static func average(
    _ values: [Double], weights: [Double], _ aggregation: HealthDataType.Aggregation
  ) -> Double {
    var accumulator = CardAccumulator(aggregation)
    for (value, weight) in zip(values, weights) { accumulator.add(value, weight: weight) }
    return accumulator.average
  }
}

/// Numbers for the few sources a type's readings come from, in the order they're met. A source
/// usually repeats the one before, which is compared first: fetchers share one string per source,
/// so that's a pointer comparison rather than a hash of a bundle ID per reading.
struct CardSources {
  private var sources: [String] = []
  private var last = -1

  mutating func index(of source: String) -> Int {
    if last >= 0, sources[last] == source { return last }
    if let index = sources.firstIndex(of: source) {
      last = index
    } else {
      sources.append(source)
      last = sources.count - 1
    }
    return last
  }
}

/// A weighted average built a reading at a time, in the order the readings come, so it adds up
/// exactly as `CardWeights.average` does.
struct CardAccumulator {
  let isEnergy: Bool
  var weighted = 0.0
  var total = 0.0

  init(_ aggregation: HealthDataType.Aggregation) {
    isEnergy = aggregation == .discreteEquivalentContinuousLevel
  }

  mutating func add(_ value: Double, weight: Double) {
    weighted += isEnergy ? weight * pow(10, value / 10) : value * weight
    total += weight
  }

  var average: Double {
    guard total > 0 else { return 0 }
    return isEnergy ? 10 * log10(weighted / total) : weighted / total
  }
}

/// A bucket's readings, aggregated as they come (oldest first): what every aggregation needs.
struct CardBucket {
  var average: CardAccumulator
  var count = 0
  var minimum = Double.infinity
  var maximum = -Double.infinity
  /// Kept only for `first` and `latest`, which need them.
  let keepsOrder: Bool
  var first: CardReading?
  var latest: CardReading?

  init(_ aggregation: HealthDataType.Aggregation, keepsOrder: Bool) {
    average = CardAccumulator(aggregation)
    self.keepsOrder = keepsOrder
  }

  mutating func add(_ reading: CardReading, weight: Double) {
    average.add(reading.value, weight: weight)
    count += 1
    minimum = min(minimum, reading.value)
    maximum = max(maximum, reading.value)
    guard keepsOrder else { return }
    if first.map({ Self.startsBefore(reading, $0) }) ?? true { first = reading }
    if latest.map({ Self.startsBefore($0, reading) }) ?? true { latest = reading }
  }

  /// Whether `a` comes before `b`: by start, then end, then sample ID. `first` is the smallest,
  /// `latest` the greatest.
  static func startsBefore(_ a: CardReading, _ b: CardReading) -> Bool {
    (a.start, a.end, a.sampleID) < (b.start, b.end, b.sampleID)
  }

  /// The bucket's value by `aggregation`; `nil` without readings.
  func value(_ aggregation: CardSpec.Aggregation) -> Double? {
    guard count > 0 else { return nil }
    switch aggregation {
    case .avg: return average.average
    case .min: return minimum
    case .max: return maximum
    case .first: return first?.value
    case .latest: return latest?.value
    case .count: return Double(count)
    // Totals aren't readings.
    case .sum: return nil
    }
  }
}
