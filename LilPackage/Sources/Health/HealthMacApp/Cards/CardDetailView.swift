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
  /// The period shown, or the latest with data before it.
  @State private var offset: Int
  /// Loaded by the view's task, with the period and spec it's for.
  @Fetch private var chart: CardPeriod? = nil

  init(spec: CardSpec) {
    self.spec = spec
    let range = spec.range
    _range = State(initialValue: range)
    // Read before the page first draws, as Metric Detail's, so it never shows another period
    // first and then moves (851-3084).
    @Dependency(\.defaultDatabase) var database
    _offset = State(initialValue: (try? database.read { try spec.openingOffset($0) }) ?? 0)
  }

  private var request: CardDataRequest {
    CardDataRequest(spec: spec, range: range, offset: offset)
  }

  var body: some View {
    CardDetailContent(spec: spec, range: $range, offset: $offset, state: state)
      .task(id: request) {
        _ = try? await $chart.load(request, scheduler: MainQueueScheduler())
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
  /// The period of its range a card's page and the editor's preview open on, as an offset from
  /// the current one: its headline's (`HealthDatabase.cardOpeningDate`, 851-3987), so a card with
  /// a window or filter opens where its Summary row's value is, not on its type's latest data.
  func openingOffset(_ db: Database) throws -> Int {
    // The caller's dependencies (a fetch's, which SQLiteData passes on), so snapshot catalogs
    // fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
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
  @Binding private var selectedOffset: Int
  let state: State
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.calendar) private var calendar
  @Dependency(\.date.now) private var now

  init(spec: CardSpec, range: Binding<CardRange>, offset: Binding<Int>, state: State) {
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
        range: $selectedRange, offset: $selectedOffset,
        ranges: spec.bucket.ranges, now: now, calendar: calendar))
  }
}
