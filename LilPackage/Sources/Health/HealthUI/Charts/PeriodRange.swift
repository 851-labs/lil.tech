public import Foundation
public import HealthCards

/// A page's ranges, such as D, W, M, 6M and Y (`ChartRange` on the Mac, `CardRange` on a card's
/// page, 851-3212) or Sleep's D and W.
public protocol PeriodRange: CaseIterable, Hashable, RawRepresentable<String>, Sendable {
  /// What one of the range's periods is called, e.g. "Week" for W.
  var periodName: String { get }
  /// The start of the first day the period `offset` periods from the current one shows.
  func firstDay(offset: Int, now: Date, calendar: Calendar) -> Date
  /// The start of the last day the period `offset` periods from the current one shows, which
  /// for the current one can be after today (this week's Saturday).
  func lastDay(offset: Int, now: Date, calendar: Calendar) -> Date
  /// How many periods from the current one the one containing `date` is (0 the current one, -1
  /// the one before).
  func offset(containing date: Date, now: Date, calendar: Calendar) -> Int
}

extension PeriodRange {
  /// The period a page opens on (851-3188): the one with its latest data, `latest`, when that's
  /// before the current one, so a type last recorded weeks ago doesn't open on an empty period.
  /// Otherwise, or without any data, the current one.
  public func openingOffset(latest: Date?, now: Date, calendar: Calendar) -> Int {
    guard let latest else { return 0 }
    return min(offset(containing: latest, now: now, calendar: calendar), 0)
  }

  /// This range's period with most of what `range`'s period `offset` shows: what choosing it
  /// shows (851-3188). From the current period, the current one. A longer range's is the one
  /// with its middle day (W → M: the month with most of the week); a shorter range's the last
  /// one mostly inside it (M → W: the month's last week, unless that's mostly the next month's),
  /// so going back and forth comes back to the same period. Ranges are listed shortest first.
  public func offset(showing range: Self, offset: Int, now: Date, calendar: Calendar) -> Int {
    guard offset < 0 else { return 0 }
    let first = range.firstDay(offset: offset, now: now, calendar: calendar)
    let last = range.lastDay(offset: offset, now: now, calendar: calendar)
    let all = Array(Self.allCases)
    guard let index = all.firstIndex(of: self), let shown = all.firstIndex(of: range),
      index < shown
    else {
      return min(
        self.offset(containing: middleDay(first, last, calendar), now: now, calendar: calendar), 0)
    }
    var target = min(self.offset(containing: last, now: now, calendar: calendar), 0)
    let middle = middleDay(
      firstDay(offset: target, now: now, calendar: calendar),
      lastDay(offset: target, now: now, calendar: calendar), calendar)
    if middle > last { target -= 1 }
    return target
  }
}

/// The day halfway from `first` to `last`, the earlier of two.
private func middleDay(_ first: Date, _ last: Date, _ calendar: Calendar) -> Date {
  let days = calendar.dateComponents([.day], from: first, to: last).day ?? 0
  return calendar.date(byAdding: .day, value: days / 2, to: first) ?? first
}

// A card's page offers its bucket's ranges (851-3207), on both apps (851-3212).
extension CardRange: PeriodRange {
  public func firstDay(offset: Int, now: Date, calendar: Calendar) -> Date {
    interval(offset: offset, now: now, calendar: calendar).start
  }

  public func lastDay(offset: Int, now: Date, calendar: Calendar) -> Date {
    let interval = interval(offset: offset, now: now, calendar: calendar)
    return calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
  }

  public var periodName: String {
    switch self {
    case .day: "Day"
    case .week: "Week"
    case .month: "Month"
    case .sixMonths: "6 Months"
    case .year: "Year"
    }
  }
}
