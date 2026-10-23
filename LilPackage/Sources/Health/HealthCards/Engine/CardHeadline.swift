public import Foundation

/// What a card's Summary row shows: the lead's latest value, when it's from, and a sparkline of
/// the buckets ending on it (docs/decisions/cards.md, Summary and headline).
///
/// Engines find it the same way, by `CardSpec.headlineLookup`:
/// - `latestReading`: the lead type's latest reading started by now; its value and time, and a run
///   of the 7 days ending on its day (`CardRun(headlineOf:endingOn:calendar:)`).
/// - `latestData`: the bucket holding the lead type's latest data started by now (the Mac's
///   `latestPeriodDate`), and a run of the 7 buckets ending on it.
/// - `search`: runs of 7 buckets ending with now's, then 7 earlier each time
///   (`searchEnds(for:now:calendar:)`), until one has a lead value.
public struct CardHeadline: Equatable, Sendable {
  public var value: Double
  /// The reading's start, or the bucket's.
  public var date: Date
  public var kind: Kind
  /// The run its sparkline draws: the buckets ending on it.
  public var data: CardData

  public enum Kind: Hashable, Sendable {
    /// A moment: Summary shows the reading's time.
    case reading
    /// A bucket, dated by it ("Oct 20", "Week of Oct 13"): `data.grain` says which.
    case bucket
  }

  public init(value: Double, date: Date, kind: Kind, data: CardData) {
    self.value = value
    self.date = date
    self.kind = kind
    self.data = data
  }

  /// The buckets a sparkline shows.
  public static let sparklineBuckets = 7
  /// How many runs a search tries before it's No Data: 8 weeks of days.
  public static let searchRounds = 8

  /// A sparkline's buckets: the card's, with `auto` as days.
  public static func grain(of spec: CardSpec) -> CardGrain {
    spec.bucket == .auto ? .day : spec.bucket.grain(at: .week)
  }

  /// The lead's latest bucket with a value in a headline's run, or `nil` without one.
  public init?(latestBucketOf data: CardData) {
    guard let point = data.leadPoints.last else { return nil }
    self.init(value: point.value, date: point.start, kind: .bucket, data: data)
  }

  /// The dates whose buckets a search's runs end with, in order: now's, then 7 buckets before
  /// each.
  public static func searchEnds(for spec: CardSpec, now: Date, calendar: Calendar) -> [Date] {
    let grain = grain(of: spec)
    var ends = [now]
    while ends.count < searchRounds, let last = ends.last {
      ends.append(calendar.bucketStart(grain, sparklineBuckets, before: last))
    }
    return ends
  }
}

extension CardSpec {
  /// How a card's headline is found.
  public enum HeadlineLookup: Hashable, Sendable {
    /// The type's latest reading and when it was, as Summary shows heart rate and weight.
    case latestReading(type: String)
    /// The latest bucket, found from the type's latest data, as Summary shows a day's steps.
    case latestData(type: String)
    /// Runs back from now, for a lead with a window or filter, or a formula.
    case search
  }

  /// How the card's headline is found: a lead that's a discrete series, `avg` or `latest`,
  /// `auto`, with no window, filter or formula, shows its latest reading; another without a
  /// window or filter, its latest bucket; the rest search. `nil` with nothing visible.
  public var headlineLookup: HeadlineLookup? {
    switch lead {
    case nil: return nil
    case .formula: return .search
    case .series(let series):
      guard series.window == nil, series.filter == nil else { return .search }
      if series.aggregation == .avg || series.aggregation == .latest, bucket == .auto,
        formulas.isEmpty
      {
        return .latestReading(type: series.type)
      }
      return .latestData(type: series.type)
    }
  }
}
