import Dependencies
public import HealthDatabase
import SQLiteData
public import SwiftUI

/// A page's ranges, such as D, W, M, 6M and Y (`ChartRange`) or Sleep's D and W.
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
  /// shows (851-3188). A longer range's has its middle day (W → M: the month with most of the
  /// week), a shorter range's its last (M → W: the month's last week); today at the latest, so
  /// the current period stays the current one. Ranges are listed shortest first.
  func offset(showing range: Self, offset: Int, now: Date, calendar: Calendar) -> Int {
    let all = Array(Self.allCases)
    let last = range.lastDay(offset: offset, now: now, calendar: calendar)
    var day = last
    if let longer = all.firstIndex(of: self), let shorter = all.firstIndex(of: range),
      longer > shorter
    {
      let first = range.firstDay(offset: offset, now: now, calendar: calendar)
      let days = calendar.dateComponents([.day], from: first, to: last).day ?? 0
      day = calendar.date(byAdding: .day, value: days / 2, to: first) ?? last
    }
    return min(self.offset(containing: min(day, now), now: now, calendar: calendar), 0)
  }
}

extension PeriodRange {
  /// `openingOffset(latest:now:calendar:)` for a type's latest data in the database, read when
  /// the page is made, before it first draws, so it never shows the current period and then
  /// moves (851-3084). One seek of an index (`HealthDatabase.latestPeriodDate`), on the main
  /// thread: a pool's reads don't wait for sync's writes.
  public func openingOffset(of typeID: String) -> Int {
    @Dependency(\.defaultDatabase) var database
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    let latest = try? database.read { db in
      try HealthDatabase.latestPeriodDate(of: typeID, by: now, calendar: calendar, db)
    }
    return openingOffset(latest: latest ?? nil, now: now, calendar: calendar)
  }
}

extension ChartRange: PeriodRange {
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
  /// The index in `ranges` of the one shown, when this was made. What's shown and compared; the
  /// actions read the page's state itself, so presses that come faster than the page redraws
  /// (a held ⌘←) each count.
  public let selected: Int
  /// 0 is the current period, -1 the one before, when this was made.
  public let offset: Int
  /// The page's range, as an index in `ranges`. Setting it keeps the time shown, moving to the
  /// range's period with most of the shown one (W → M shows the week's month, 851-3188), in the
  /// same change, so it loads once.
  let rangeSelection: Binding<Int>
  private let liveOffset: Binding<Int>

  /// `now` and `calendar` are what the page's periods are counted from.
  public init<R: PeriodRange>(
    range: Binding<R>, offset: Binding<Int>, now: Date, calendar: Calendar
  ) {
    let all = Array(R.allCases)
    ranges = all.map { Range(label: $0.rawValue, name: $0.periodName) }
    selected = all.firstIndex(of: range.wrappedValue) ?? 0
    self.offset = offset.wrappedValue
    rangeSelection = Binding(
      get: { all.firstIndex(of: range.wrappedValue) ?? 0 },
      set: { index in
        guard all.indices.contains(index), all[index] != range.wrappedValue else { return }
        let next = all[index]
        (range.wrappedValue, offset.wrappedValue) = (
          next,
          next.offset(
            showing: range.wrappedValue, offset: offset.wrappedValue, now: now, calendar: calendar)
        )
      })
    liveOffset = offset
  }

  /// The name of the shown range's periods, e.g. "Week".
  public var name: String { ranges[selected].name }

  /// Shows the range at `index`, at its period with most of the one shown. Choosing the one
  /// shown changes nothing.
  public func select(_ index: Int) {
    rangeSelection.wrappedValue = index
  }

  public func previous() { liveOffset.wrappedValue -= 1 }
  public func today() { liveOffset.wrappedValue = 0 }
  public func next() {
    guard liveOffset.wrappedValue < 0 else { return }
    liveOffset.wrappedValue += 1
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
            Picker("Range", selection: period.rangeSelection) {
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
