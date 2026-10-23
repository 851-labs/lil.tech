public import Foundation

// Periods and buckets (docs/decisions/cards.md, Bucket and range): the calendar's, in the engine's
// time zone and first weekday, as Metric Detail has them.

/// What one point covers, once `auto` is resolved: a clock hour, or a calendar day, week or month.
public enum CardGrain: String, CaseIterable, Hashable, Sendable {
  case hour, day, week, month

  /// The calendar unit of one bucket.
  public var component: Calendar.Component {
    switch self {
    case .hour: .hour
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    }
  }
}

extension CardRange {
  /// What each point covers at this range, as Metric Detail: an hour (D), a day (W, M), a week
  /// (6M), a month (Y).
  public var grain: CardGrain {
    switch self {
    case .day: .hour
    case .week, .month: .day
    case .sixMonths: .week
    case .year: .month
    }
  }

  /// The period `offset` periods from the one containing `now` (0 is the current one, -1 the one
  /// before): a calendar day, week, month or year, or the six calendar months ending with the
  /// date's. Metric Detail's periods (`ChartRange`), which call this.
  public func interval(offset: Int, now: Date, calendar: Calendar) -> DateInterval {
    func shifted(_ component: Calendar.Component, _ value: Int) -> DateInterval {
      let base =
        calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
      let start = calendar.date(byAdding: component, value: value, to: base.start) ?? base.start
      return calendar.dateInterval(of: component, for: start) ?? base
    }
    switch self {
    case .day: return shifted(.day, offset)
    case .week: return shifted(.weekOfYear, offset)
    case .month: return shifted(.month, offset)
    case .year: return shifted(.year, offset)
    case .sixMonths:
      // The six months ending with the current month, then the six before them.
      let month = shifted(.month, offset * 6)
      let start = calendar.date(byAdding: .month, value: -5, to: month.start) ?? month.start
      return DateInterval(start: start, end: month.end)
    }
  }

  /// How many periods from the one containing `now` the one containing `date` is: 0 for the
  /// current one, -1 for the one before, positive for one after.
  public func offset(containing date: Date, now: Date, calendar: Calendar) -> Int {
    /// Whole `component`s from the one containing `now` to the one containing `date`.
    func distance(_ component: Calendar.Component) -> Int {
      guard let from = calendar.dateInterval(of: component, for: now)?.start,
        let to = calendar.dateInterval(of: component, for: date)?.start
      else { return 0 }
      return calendar.dateComponents([component], from: from, to: to).value(for: component) ?? 0
    }
    var offset =
      switch self {
      case .day: distance(.day)
      case .week: distance(.weekOfYear)
      case .month: distance(.month)
      case .year: distance(.year)
      // Six months ending with the current month's: months -5 to 0 are 0, -11 to -6 are -1.
      case .sixMonths: Int((Double(distance(.month)) / 6).rounded(.up))
      }
    // Settled against the intervals themselves, which are what the page shows.
    for _ in 0..<4 {
      let interval = interval(offset: offset, now: now, calendar: calendar)
      if date < interval.start {
        offset -= 1
      } else if date >= interval.end {
        offset += 1
      } else {
        break
      }
    }
    return offset
  }

  /// The period containing `date`, among those `interval(offset:now:calendar:)` gives: 6M's are
  /// the six months ending with `now`'s, then the six before them.
  public func interval(containing date: Date, now: Date, calendar: Calendar) -> DateInterval {
    interval(
      offset: offset(containing: date, now: now, calendar: calendar), now: now, calendar: calendar)
  }
}

extension CardSpec.Bucket {
  /// What each point covers at `range`: the range's grain for `auto`, else the bucket's own. A
  /// `night` bucket is its night's day for series without a sleep window (851-3196 places sleep
  /// windows' readings at their nights).
  public func grain(at range: CardRange) -> CardGrain {
    switch self {
    case .auto: range.grain
    case .hour: .hour
    case .day, .night: .day
    case .week: .week
    case .month: .month
    }
  }
}

/// Finds the bucket a moment falls in, asking the calendar only when a moment leaves the last
/// bucket, so a year of readings costs a calendar call per bucket rather than per reading.
public struct CardBucketer: Sendable {
  let component: Calendar.Component
  let calendar: Calendar
  private var current: (start: Int, end: Int, date: Date)?

  public init(_ grain: CardGrain, calendar: Calendar) {
    self.init(grain.component, calendar: calendar)
  }

  public init(_ component: Calendar.Component, calendar: Calendar) {
    self.component = component
    self.calendar = calendar
  }

  /// One bucket: all of `range`.
  public init(whole range: Range<Date>) {
    component = .era
    calendar = Calendar(identifier: .gregorian)
    current = (
      range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds, range.lowerBound
    )
  }

  /// The start of the bucket containing `milliseconds` (Unix).
  public mutating func start(ofMilliseconds milliseconds: Int) -> Date {
    if let current, current.start <= milliseconds, milliseconds < current.end {
      return current.date
    }
    return start(of: Date(unixMilliseconds: milliseconds))
  }

  /// The start of the bucket containing `date`.
  public mutating func start(of date: Date) -> Date {
    if let current, current.date <= date, date.unixMilliseconds < current.end {
      return current.date
    }
    guard let interval = calendar.dateInterval(of: component, for: date) else {
      current = nil
      return date
    }
    current = (interval.start.unixMilliseconds, interval.end.unixMilliseconds, interval.start)
    return interval.start
  }
}

extension Calendar {
  /// The starts of the buckets from the one containing `start` up to `end`, in order.
  func bucketStarts(_ grain: CardGrain, from start: Date, to end: Date) -> [Date] {
    var starts: [Date] = []
    var date = dateInterval(of: grain.component, for: start)?.start ?? start
    while date < end {
      starts.append(date)
      guard let next = dateInterval(of: grain.component, for: date)?.end, next > date else { break }
      date = next
    }
    return starts
  }

  /// The start of the bucket `count` buckets before the one containing `date`.
  func bucketStart(_ grain: CardGrain, _ count: Int, before date: Date) -> Date {
    let start = dateInterval(of: grain.component, for: date)?.start ?? date
    guard count > 0 else { return start }
    let earlier = self.date(byAdding: grain.component, value: -count, to: start) ?? start
    return dateInterval(of: grain.component, for: earlier)?.start ?? earlier
  }
}

extension Date {
  init(unixMilliseconds: Int) {
    self.init(timeIntervalSince1970: Double(unixMilliseconds) / 1000)
  }

  var unixMilliseconds: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}
