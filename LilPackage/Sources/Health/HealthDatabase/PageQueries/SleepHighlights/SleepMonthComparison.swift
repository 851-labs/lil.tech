public import Foundation

/// This month's average time asleep against last month's (851-3103), over the nights with sleep
/// in each: calendar months, this one so far.
public struct SleepMonthComparison: Equatable, Sendable {
  /// The start of this month and of last month.
  public var thisMonth: Date
  public var lastMonth: Date
  /// Average time asleep a night with sleep, this month so far and last month.
  public var thisMonthAverage: TimeInterval
  public var lastMonthAverage: TimeInterval

  public init(
    thisMonth: Date, lastMonth: Date, thisMonthAverage: TimeInterval,
    lastMonthAverage: TimeInterval
  ) {
    self.thisMonth = thisMonth
    self.lastMonth = lastMonth
    self.thisMonthAverage = thisMonthAverage
    self.lastMonthAverage = lastMonthAverage
  }

  /// Nights with sleep this month needs: under a week, its average says little yet.
  public static let minimumThisMonth = 5
  /// Nights with sleep last month needs: a third of it.
  public static let minimumLastMonth = 10

  init?(nights: [SleepNight], today: Date, calendar: Calendar) {
    guard let thisMonth = calendar.dateInterval(of: .month, for: today)?.start,
      let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)
    else { return nil }
    let this = nights.filter { $0.day >= thisMonth && $0.day <= today }.map(\.asleep)
    let last = nights.filter { $0.day >= lastMonth && $0.day < thisMonth }.map(\.asleep)
    guard this.count >= Self.minimumThisMonth, last.count >= Self.minimumLastMonth else {
      return nil
    }
    self.init(
      thisMonth: thisMonth, lastMonth: lastMonth,
      thisMonthAverage: this.reduce(0, +) / Double(this.count),
      lastMonthAverage: last.reduce(0, +) / Double(last.count))
  }

  /// More, less or about the same: a change under 5% is about the same, as Summary's weeks are.
  public var direction: Highlight.Direction {
    guard lastMonthAverage > 0 else { return thisMonthAverage > 0 ? .up : .same }
    let change = (thisMonthAverage - lastMonthAverage) / lastMonthAverage
    if change >= HealthDatabase.weekChange { return .up }
    if change <= -HealthDatabase.weekChange { return .down }
    return .same
  }
}
