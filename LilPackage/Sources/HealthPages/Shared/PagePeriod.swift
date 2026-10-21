public import HealthDatabase
public import SwiftUI

/// A page's ranges, such as D, W, M, 6M and Y (`ChartRange`) or Sleep's D and W.
public protocol PeriodRange: CaseIterable, Hashable, RawRepresentable<String> {
  /// What one of the range's periods is called, e.g. "Week" for W.
  var periodName: String { get }
}

extension ChartRange: PeriodRange {
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

/// The range and period a page shows, for its toolbar and the View menu's commands (851-2821,
/// 851-2866): whichever ranges the page has, and how many periods back it is. Pages publish it
/// with `periodControls(_:)`.
public struct PagePeriod: Equatable {
  /// A range's short label ("W") and its period's name ("Week"), in order.
  public struct Range: Equatable, Sendable {
    public let label: String
    public let name: String
  }

  public let ranges: [Range]
  /// The index in `ranges` of the one shown.
  public let selected: Int
  /// 0 is the current period, -1 the one before.
  public let offset: Int
  private let choose: (Int) -> Void
  private let move: (Int) -> Void

  public init<R: PeriodRange>(range: Binding<R>, offset: Binding<Int>) {
    let all = Array(R.allCases)
    ranges = all.map { Range(label: $0.rawValue, name: $0.periodName) }
    selected = all.firstIndex(of: range.wrappedValue) ?? 0
    self.offset = offset.wrappedValue
    // A new range starts at its current period, in the same change, so it loads once.
    choose = { index in (range.wrappedValue, offset.wrappedValue) = (all[index], 0) }
    move = { offset.wrappedValue = $0 }
  }

  /// The name of the shown range's periods, e.g. "Week".
  public var name: String { ranges[selected].name }

  /// Shows the range at `index`, from its current period. Choosing the one shown changes nothing.
  public func select(_ index: Int) {
    guard index != selected, ranges.indices.contains(index) else { return }
    choose(index)
  }

  public func previous() { move(offset - 1) }
  public func today() { move(0) }
  public func next() {
    guard canGoForward else { return }
    move(offset + 1)
  }

  public var isCurrent: Bool { offset == 0 }
  /// Nothing after the current period has data yet.
  public var canGoForward: Bool { offset < 0 }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.ranges == rhs.ranges && lhs.selected == rhs.selected && lhs.offset == rhs.offset
  }
}

extension FocusedValues {
  /// The shown page's period, while there is one.
  @Entry public var pagePeriod: PagePeriod?
}

extension View {
  /// The page's range in the middle of the toolbar and ‹ Today › on its trailing side, as
  /// Calendar has them, and its period for the View menu's commands while it's on screen (not
  /// under a page pushed from it). Only on this page: other pages' toolbars stay as they are.
  public func periodControls(_ period: PagePeriod) -> some View {
    modifier(PeriodControls(period: period))
  }
}

private struct PeriodControls: ViewModifier {
  let period: PagePeriod
  @State private var isShown = false

  func body(content: Content) -> some View {
    content
      .toolbar {
        if period.ranges.count > 1 {
          ToolbarItem(placement: .principal) {
            Picker(
              "Range", selection: Binding(get: { period.selected }, set: { period.select($0) })
            ) {
              ForEach(period.ranges.indices, id: \.self) { index in
                Text(period.ranges[index].label).tag(index)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Choose how much time to show")
          }
        }
        // One group, as Calendar's ‹ Today › are. The View menu lists their shortcuts.
        ToolbarItemGroup(placement: .primaryAction) {
          let name = period.name.lowercased()
          Button("Previous \(period.name)", systemImage: "chevron.left") { period.previous() }
            .help("Show the previous \(name)")
          Button("Today") { period.today() }
            .disabled(period.isCurrent)
            .help("Show the current \(name)")
          Button("Next \(period.name)", systemImage: "chevron.right") { period.next() }
            .disabled(!period.canGoForward)
            .help("Show the next \(name)")
        }
      }
      .focusedSceneValue(\.pagePeriod, isShown ? period : nil)
      .onAppear { isShown = true }
      .onDisappear { isShown = false }
  }
}
