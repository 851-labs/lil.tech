import HealthDatabase
public import HealthPages
public import SwiftUI

extension FocusedValues {
  /// Whether the sidebar's search field has focus, where ⌘← and ⌘→ move the cursor.
  @Entry var isSearchFocused: Bool?
}

/// The View menu's commands for a page with a period (a metric, Sleep): ⌘1 to ⌘5 for its ranges
/// (D, W, M, 6M and Y on a metric), ⌘← and ⌘→ for the previous and next period, and ⌘T for the
/// current one, as in Calendar (851-2821, 851-2866). Disabled on other pages, and the arrows while
/// the search field has focus, so they still move its cursor.
public struct PeriodCommands: Commands {
  @FocusedValue(\.pagePeriod) private var period
  @FocusedValue(\.isSearchFocused) private var isSearchFocused

  public init() {}

  public var body: some Commands {
    let arrows = period.flatMap { isSearchFocused == true ? nil : $0 }
    // A metric's ranges while there's no page, so the menu shows what it's for.
    let names = period?.ranges.map(\.name) ?? ChartRange.allCases.map(\.periodName)
    CommandGroup(before: .sidebar) {
      ForEach(Array(names.enumerated()), id: \.offset) { index, name in
        Button(name) { period?.select(index) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
          .disabled(period == nil)
      }
      Divider()
      Button("Previous \(period?.name ?? "Period")") { arrows?.previous() }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(arrows == nil)
      Button("Today") { period?.today() }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(period.map(\.isCurrent) ?? true)
      Button("Next \(period?.name ?? "Period")") { arrows?.next() }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(!(arrows?.canGoForward ?? false))
      Divider()
    }
  }
}
