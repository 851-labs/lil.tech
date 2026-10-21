import HealthDatabase
public import SwiftUI

/// The period a metric page shows, for its toolbar and the View menu's commands (851-2821).
struct MetricPeriod {
  @Binding var range: ChartRange
  /// 0 is the current period, -1 the one before.
  @Binding var offset: Int

  /// Choosing a range starts at its current period, in the same change, so it loads once.
  var rangeSelection: Binding<ChartRange> {
    Binding(get: { range }, set: { select($0) })
  }

  func select(_ newRange: ChartRange) {
    (range, offset) = (newRange, 0)
  }
}

extension FocusedValues {
  /// The shown metric page's period, while there is one.
  @Entry var metricPeriod: MetricPeriod?
}

extension ChartRange {
  /// What one of the range's periods is called, e.g. "Week" for W.
  var periodName: String {
    switch self {
    case .day: "Day"
    case .week: "Week"
    case .month: "Month"
    case .sixMonths: "6 Months"
    case .year: "Year"
    }
  }
}

/// The View menu's commands for a metric page: ⌘1 to ⌘5 for D, W, M, 6M and Y, ⌘← and ⌘→ for the
/// previous and next period, and ⌘T for the current one, as in Calendar. Disabled on other pages.
public struct MetricPeriodCommands: Commands {
  @FocusedValue(\.metricPeriod) private var period

  public init() {}

  public var body: some Commands {
    CommandGroup(before: .sidebar) {
      ForEach(Array(ChartRange.allCases.enumerated()), id: \.element) { index, range in
        Button(range.periodName) { period?.select(range) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
          .disabled(period == nil)
      }
      Divider()
      Button("Previous \(period?.range.periodName ?? "Period")") { period?.offset -= 1 }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(period == nil)
      Button("Today") { period?.offset = 0 }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(period.map { $0.offset == 0 } ?? true)
      Button("Next \(period?.range.periodName ?? "Period")") { period?.offset += 1 }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(period.map { $0.offset >= 0 } ?? true)
      Divider()
    }
  }
}
