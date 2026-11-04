import ComposableArchitecture
import HealthCards
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import LilUI
import SQLiteData
import SwiftUI

// The full-page card (851-3207, docs/decisions/cards.md, UI › Mac): Metric Detail's page for a
// card. Every card on Summary opens it, the welcome seed's included.

/// A card's page, by its ID, from the account's cards: it follows the card as it's edited or
/// synced, and says so when it's deleted.
struct CardPage: View {
  let store: StoreOf<CardsFeature>
  let id: Card.ID
  /// Whether the local data holds the cards, as Summary asks (`SummaryView`): until it does, no
  /// cards is loading, not a deleted card.
  @Fetch private var holdsCards = false

  init(store: StoreOf<CardsFeature>, id: Card.ID) {
    self.store = store
    self.id = id
    _holdsCards = Fetch(wrappedValue: false, HoldsCardsRequest(), scheduler: MainQueueScheduler())
  }

  /// Whether the cards are still loading, as Summary's section decides it.
  private var isLoading: Bool {
    store.isLoading || store.cards.isEmpty && !holdsCards && $holdsCards.loadError == nil
  }

  var body: some View {
    if let card = store.cards[id: id] {
      CardDetailView(card: card)
        .toolbar {
          // The editor (851-3208). A later version's card can't be edited here.
          ToolbarItem(placement: .primaryAction) {
            Button("Edit…", systemImage: "pencil") {
              store.send(.editCardButtonTapped(id: id))
            }
            .help("Edit Card")
            .disabled(card.spec == nil)
          }
        }
    } else if let failure = store.loadFailure {
      ContentUnavailableView(
        "Couldn't Load This Card", systemImage: "exclamationmark.triangle",
        description: Text(failure))
    } else if isLoading {
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

/// A card's page: its chart over a period it loads, or, for a card of a later version, that this
/// version can't show it.
struct CardDetailView: View {
  let card: Card

  var body: some View {
    if let spec = card.spec {
      CardChartPage(spec: spec)
        // A new bucket offers other ranges: the page opens again, on the card's own.
        .id(spec.bucket)
    } else {
      CardUnreadableContent(card: card)
    }
  }
}

/// A card over a chosen period, as Metric Detail charts a type: the bucket's ranges and earlier
/// periods in the toolbar, opening on the period of its latest data (851-3188, 851-3987), and
/// keeping the period shown while the next loads (851-3084). Follows the local database as sync
/// changes it.
struct CardChartPage: View {
  let spec: CardSpec
  @State private var range: CardRange
  /// The period shown, 0 the current one: `nil` while the page looks for the period it opens on.
  @State private var offset: Int? = nil
  /// Loaded by the view's task, with the period and spec it's for.
  @Fetch private var chart: CardPeriod? = nil
  @Dependency(\.defaultDatabase) private var database
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  init(spec: CardSpec) {
    self.spec = spec
    let range = spec.range
    _range = State(initialValue: range)
    // Without a window, filter or formula, one seek of an index, read before the page first
    // draws, as Metric Detail's, so it never shows another period first and then moves
    // (851-3084). With one, the headline's search, which the page's task runs off the main
    // thread, with the dates "–" until it knows the period, as the iPhone's page does.
    if spec.headlineLookup != .search {
      @Dependency(\.defaultDatabase) var database
      @Dependency(\.date.now) var now
      @Dependency(\.calendar) var calendar
      _offset = State(
        initialValue: (try? database.read {
          try spec.openingOffset(in: range, now: now, calendar: calendar, $0)
        }) ?? 0)
    }
  }

  /// What the page loads: the period chosen, or, before it knows which, the one it opens on.
  private struct Load: Equatable {
    var spec: CardSpec
    var range: CardRange
    var offset: Int?
  }

  var body: some View {
    CardDetailContent(spec: spec, range: $range, offset: $offset, state: state)
      .task(id: Load(spec: spec, range: range, offset: offset)) {
        guard let offset else {
          // `offset` changes the task's ID, which runs it again for that period.
          let (spec, range, now, calendar) = (spec, range, now, calendar)
          let opening = try? await database.read { db in
            try spec.openingOffset(in: range, now: now, calendar: calendar, db)
          }
          guard !Task.isCancelled, self.offset == nil else { return }
          self.offset = opening ?? 0
          return
        }
        _ = try? await $chart.load(
          CardDataRequest(spec: spec, range: range, offset: offset),
          scheduler: MainQueueScheduler())
      }
  }

  /// The chart loaded last, updating while it's another period's, or the spec before an edit, or
  /// a load is running.
  private var state: CardDetailContent.State {
    if let error = $chart.loadError { return .failed(error.localizedDescription) }
    guard let chart else { return .loading }
    return .loaded(
      chart,
      isUpdating: $chart.isLoading || chart.range != range || chart.offset != offset
        || chart.spec != spec)
  }
}

extension CardSpec {
  /// The period of `range` a card's page and the editor's preview open on, as an offset from the
  /// current one: its headline's (`HealthDatabase.cardOpeningDate`, 851-3987), so a card with a
  /// window or filter opens where its Summary row's value is, not on its type's latest data.
  func openingOffset(
    in range: CardRange, now: Date, calendar: Calendar, _ db: Database
  ) throws -> Int {
    let latest = try HealthDatabase.cardOpeningDate(self, now: now, calendar: calendar, db)
    return range.openingOffset(latest: latest, now: now, calendar: calendar)
  }
}

/// A card over the period `offset` periods from the current one of `range`, from the local
/// database (`HealthDatabase.cardData`).
struct CardDataRequest: FetchKeyRequest {
  let spec: CardSpec
  let range: CardRange
  let offset: Int

  func fetch(_ db: Database) throws -> CardPeriod? {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    let period = range.interval(offset: offset, now: now, calendar: calendar)
    let data = try HealthDatabase.cardData(
      spec, range: range, date: period.start, now: now, calendar: calendar, db)
    return CardPeriod(range: range, offset: offset, spec: spec, data: data)
  }
}

/// What a card's page shows, however it got it: a grouped form with the header and chart, the
/// legend when it draws more than one line, About This Card, and for a card of one series, its
/// type's Show All Data and Data Sources.
struct CardDetailContent: View {
  typealias State = CardChart.State

  let spec: CardSpec
  /// The period chosen in the toolbar, which can be ahead of the one shown.
  @Binding private var selectedRange: CardRange
  /// `nil` until the page knows which period it opens on: its dates read "–" until then.
  @Binding private var selectedOffset: Int?
  let state: State
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.calendar) private var calendar
  @Dependency(\.date.now) private var now

  init(spec: CardSpec, range: Binding<CardRange>, offset: Binding<Int?>, state: State) {
    self.spec = spec
    _selectedRange = range
    _selectedOffset = offset
    self.state = state
  }

  /// The one type a card of one series charts, whose data it can show.
  private var singleType: HealthDataType? {
    spec.series.count == 1 ? spec.series.first?.dataType : nil
  }

  var body: some View {
    Form {
      Section {
        CardChart(spec: spec, range: selectedRange, offset: selectedOffset, state: state)
          .padding(.vertical, 6)
      }
      Section("About This Card") {
        Text(spec.about)
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutAnchor("About This Card")
      }
      if let type = singleType {
        Section {
          NavigationLink("Show All Data") {
            AllDataView(type: type)
          }
          NavigationLink("Data Sources") {
            DataSourcesView(type: type)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(spec.display.name)
    // Only the bucket's ranges, in the toolbar, with ‹ Today › and the View menu's commands.
    .periodControls(
      PagePeriod(
        range: $selectedRange,
        offset: Binding(get: { selectedOffset ?? 0 }, set: { selectedOffset = $0 }),
        ranges: spec.bucket.ranges, now: now, calendar: calendar))
  }
}
