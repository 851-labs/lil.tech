import HealthDatabase
public import SwiftUI

/// The period a metric page shows, for its toolbar and the View menu's commands (851-2821).
struct MetricPeriod: Equatable {
  @Binding var range: ChartRange
  /// 0 is the current period, -1 the one before.
  @Binding var offset: Int

  /// Choosing a range starts at its current period, in the same change, so it loads once.
  /// Choosing the one shown changes nothing.
  var rangeSelection: Binding<ChartRange> {
    Binding(get: { range }, set: { select($0) })
  }

  func select(_ newRange: ChartRange) {
    guard newRange != range else { return }
    (range, offset) = (newRange, 0)
  }

  func previous() { offset -= 1 }
  func today() { offset = 0 }
  func next() {
    guard canGoForward else { return }
    offset += 1
  }

  var isCurrent: Bool { offset == 0 }
  /// Nothing after the current period has data yet.
  var canGoForward: Bool { offset < 0 }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.range == rhs.range && lhs.offset == rhs.offset
  }
}

extension FocusedValues {
  /// The shown metric page's period, while there is one.
  @Entry var metricPeriod: MetricPeriod?
  /// Whether the sidebar's search field has focus, where ⌘← and ⌘→ move the cursor.
  @Entry var isSearchFocused: Bool?
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
/// previous and next period, and ⌘T for the current one, as in Calendar. Disabled on other pages,
/// and the arrows while the search field has focus, so they still move its cursor.
public struct MetricPeriodCommands: Commands {
  @FocusedValue(\.metricPeriod) private var period
  @FocusedValue(\.isSearchFocused) private var isSearchFocused

  public init() {}

  public var body: some Commands {
    let arrows = period.flatMap { isSearchFocused == true ? nil : $0 }
    CommandGroup(before: .sidebar) {
      ForEach(Array(ChartRange.allCases.enumerated()), id: \.element) { index, range in
        Button(range.periodName) { period?.select(range) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
          .disabled(period == nil)
      }
      Divider()
      Button("Previous \(period?.range.periodName ?? "Period")") { arrows?.previous() }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(arrows == nil)
      Button("Today") { period?.today() }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(period.map(\.isCurrent) ?? true)
      Button("Next \(period?.range.periodName ?? "Period")") { arrows?.next() }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(!(arrows?.canGoForward ?? false))
      Divider()
    }
  }
}
