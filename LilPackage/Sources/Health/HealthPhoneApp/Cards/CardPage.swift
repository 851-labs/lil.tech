import ComposableArchitecture
import Dependencies
import HealthCardStore
import HealthCards
import HealthKitAccess
import HealthUI
import LilUI
import SwiftUI

// The full-page card on the iPhone (851-3212, docs/decisions/cards.md, UI › iPhone): pushed from
// its Summary row. The Mac's page (851-3207) adapted to iOS: the range as a segmented control under
// the title, then the header and chart the Mac draws (`CardChart`, in `HealthUI`), and About This
// Card, with Metric Detail's period and layout rules (851-3084, 851-3188), computed from this
// iPhone's HealthKit (`healthKitCards`).

/// A card's page, by its ID, from the account's cards: it follows the card as it's synced, and
/// says so when it's deleted.
struct CardPage: View {
  let store: StoreOf<CardsFeature>
  let id: Card.ID
  /// Where it opens, from the card's Summary row.
  let opening: CardOpening
  /// Summary's day and generation: the page runs its card again when they change, as the rows do.
  let refresh: CardRefresh

  var body: some View {
    if let card = store.cards[id: id] {
      if let spec = card.spec {
        CardChartPage(spec: spec, opening: opening, refresh: refresh)
          // A new bucket offers other ranges: the page opens again, on the card's own.
          .id(spec.bucket)
      } else {
        UnreadableCardPage(card: card)
      }
    } else if let failure = store.loadFailure {
      ContentUnavailableView(
        "Couldn't Load This Card", systemImage: "exclamationmark.triangle",
        description: Text(failure))
    } else if store.isLoading {
      // Summary's rows link to the welcome seed's cards while they load.
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .delayedProgress(isLoading: true)
    } else {
      ContentUnavailableView(
        "No Card", systemImage: "rectangle.stack", description: Text("This card was deleted."))
    }
  }
}

/// A card of a later version's page: the Mac's (`CardUnreadableContent`), titled inline as the
/// other pages are.
struct UnreadableCardPage: View {
  let card: Card

  var body: some View {
    CardUnreadableContent(card: card)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
  }
}

/// What makes a card's page run its card again, as Summary's rows do (`CardHeadlines.Run`): the
/// day, the app coming back to the front, and what Health access is known.
struct CardRefresh: Equatable {
  var day: Date?
  var generation: Int
  /// Whether Health still has types to ask about: `nil` while it's being checked, and the page
  /// waits, loading, as the rows do (851-4035).
  var needsHealthAccess: Bool?
}

/// Which period a card's page opens on (851-3188): the one with the card's latest data, which its
/// Summary row has already found (its headline's date), or, when the row hasn't, which the page
/// finds itself before it loads a period.
enum CardOpening: Equatable {
  /// The row's headline's date: its latest reading or bucket. `nil` for No Data: the current
  /// period.
  case latest(Date?)
  /// The row hadn't run the card as it is now.
  case unknown

  /// The row's headline, when it's the card's as it is now.
  init(_ kept: (run: CardHeadlines.Run, headline: CardRow.Headline)?, spec: CardSpec?) {
    if let kept, kept.run.spec == spec, case .loaded(let headline) = kept.headline {
      self = .latest(headline?.date)
    } else {
      self = .unknown
    }
  }
}

/// A card over a chosen period, from this iPhone's HealthKit: the bucket's ranges under the title,
/// earlier periods in the toolbar, opening on the period with the card's latest data (851-3188),
/// and keeping the period shown while the next loads (851-3084).
struct CardChartPage: View {
  let spec: CardSpec
  let refresh: CardRefresh
  @State private var range: CardRange
  /// The period shown, 0 the current one: `nil` until the page knows which it opens on.
  @State private var offset: Int?
  /// The period loaded last, which stays while the next loads.
  @State private var chart: CardPeriod?
  @State private var failure: String?
  @State private var isLoading = false
  @Dependency(\.healthKitCards) private var healthKitCards
  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar

  init(spec: CardSpec, opening: CardOpening, refresh: CardRefresh) {
    self.spec = spec
    self.refresh = refresh
    let range = spec.range
    _range = State(initialValue: range)
    if case .latest(let latest) = opening {
      @Dependency(\.date.now) var now
      @Dependency(\.calendar) var calendar
      _offset = State(
        initialValue: range.openingOffset(latest: latest, now: now, calendar: calendar))
    }
  }

  /// What the page runs: the card over the period chosen, again when Summary's day or generation
  /// changes.
  private struct Request: Equatable {
    var spec: CardSpec
    var range: CardRange
    var offset: Int?
    var refresh: CardRefresh
  }

  var body: some View {
    CardDetailContent(
      spec: spec, range: rangeSelection, offset: offset, state: state,
      previous: { offset = (offset ?? 0) - 1 },
      next: { if let offset, offset < 0 { self.offset = offset + 1 } }
    )
    .task(id: Request(spec: spec, range: range, offset: offset, refresh: refresh)) {
      await load()
    }
  }

  /// The period chosen: choosing another range keeps the time shown, moving to the range's period
  /// with most of it (W → M shows the week's month, 851-3188), in one change, so it loads once.
  private var rangeSelection: Binding<CardRange> {
    Binding(
      get: { range },
      set: { next in
        guard next != range else { return }
        let shown = offset ?? 0
        (range, offset) = (
          next, next.offset(showing: range, offset: shown, now: date.now, calendar: calendar)
        )
      })
  }

  /// The chart loaded last, updating while it's another period's, or the spec before an edit, or
  /// a run is under way.
  private var state: CardChart.State {
    if let failure { return .failed(failure) }
    guard let chart else { return .loading }
    return .loaded(
      chart,
      isUpdating: isLoading || chart.range != range || chart.offset != offset || chart.spec != spec)
  }

  private func load() async {
    // Until Health access is checked, HealthKit may not answer for minutes (851-4035).
    guard refresh.needsHealthAccess != nil else { return }
    let now = date.now
    isLoading = true
    // A failure is the last run's: this one shows the period loaded last, updating, or loading.
    failure = nil
    defer { if !Task.isCancelled { isLoading = false } }
    do {
      guard let offset else {
        // The row hadn't found the latest data: find it, then load that period (`offset` changes
        // the task's ID, which runs it again).
        let headline = try await Self.headline(
          of: spec, in: healthKitCards, now: now, calendar: calendar)
        try Task.checkCancellation()
        self.offset = range.openingOffset(latest: headline?.date, now: now, calendar: calendar)
        return
      }
      let period = range.interval(offset: offset, now: now, calendar: calendar)
      let data = try await Self.data(
        of: spec, range: range, date: period.start, in: healthKitCards, now: now,
        calendar: calendar)
      try Task.checkCancellation()
      chart = CardPeriod(range: range, offset: offset, spec: spec, data: data)
      failure = nil
    } catch {
      guard !(error is CancellationError), !Task.isCancelled else { return }
      failure = error.localizedDescription
    }
  }

  /// Off the main actor: the engine weighs and aggregates the readings HealthKit returns.
  @concurrent
  private static func data(
    of spec: CardSpec, range: CardRange, date: Date, in cards: HealthKitCards, now: Date,
    calendar: Calendar
  ) async throws -> CardData {
    try await cards.data(spec, range, date, now, calendar)
  }

  @concurrent
  private static func headline(
    of spec: CardSpec, in cards: HealthKitCards, now: Date, calendar: Calendar
  ) async throws -> CardHeadline? {
    try await cards.headline(spec, now, calendar)
  }
}

/// What a card's page shows, however it got it: the bucket's ranges, the header and chart (the
/// Mac's, `CardChart`), with the legend when it draws more than one line, and About This Card.
/// Earlier and later periods are the toolbar's ‹ and ›.
struct CardDetailContent: View {
  let spec: CardSpec
  /// The range chosen, which can be ahead of the one shown.
  @Binding var range: CardRange
  /// The period chosen, `nil` until the page knows which it opens on.
  let offset: Int?
  let state: CardChart.State
  var previous: () -> Void = {}
  var next: () -> Void = {}

  /// The chart's height under the header: a little less than the Mac's 280, for a phone's screen.
  static let chartHeight: CGFloat = 240

  var body: some View {
    List {
      let ranges = spec.bucket.ranges
      if ranges.count > 1 {
        Section {
          Picker("Range", selection: $range) {
            ForEach(ranges, id: \.self) { range in
              Text(range.rawValue).tag(range)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          // Until the page knows which period it opens on: a range chosen meanwhile would open
          // on its current period, not the latest data's.
          .disabled(offset == nil)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
      }
      Section {
        CardChart(
          spec: spec, range: range, offset: offset, state: state, chartHeight: Self.chartHeight
        )
        .padding(.vertical, 6)
      }
      Section("About This Card") {
        Text(spec.about)
      }
    }
    .navigationTitle(spec.display.name)
    #if os(iOS)
      .listSectionSpacing(.compact)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        let name = range.periodName
        Button("Previous \(name)", systemImage: "chevron.left", action: previous)
          .disabled(offset == nil)
        Button("Next \(name)", systemImage: "chevron.right", action: next)
          .disabled((offset ?? 0) >= 0)
      }
    }
  }
}
