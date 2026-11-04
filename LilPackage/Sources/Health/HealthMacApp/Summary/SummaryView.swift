import ComposableArchitecture
import HealthCardEditor
import HealthCards
import HealthCatalog
import HealthDatabase
import HealthPages
import HealthUI
import LilSync
import LilUI
import SQLiteData
import SwiftUI

/// Summary: the account's cards (851-3206), a row each in their order, then highlights. Follows
/// the cards as `CardsFeature` reads them, and the cards' headlines and the highlights in the
/// local database as sync changes it.
struct SummaryView: View {
  let store: StoreOf<CardsFeature>
  /// Each card's headline, by its ID, as of the last fetch: every card's at once, at most once a
  /// second while sync writes (`CardHeadlinesRequest`, 851-3237). A card without one yet is
  /// loading.
  @State private var headlines: [Card.ID: CardRow.Headline]
  @Fetch private var highlights: [Highlight]
  /// Whether the local data holds the cards: until a first pull, or an upgraded Mac's catch-up of
  /// them, brings them, no cards isn't an empty Summary (docs/decisions/cards.md, The welcome
  /// seed).
  @Fetch private var holdsCards = false
  /// Today, so headlines and highlights move at midnight, even if nothing syncs.
  @State private var day: Date
  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.defaultDatabase) private var database

  init(store: StoreOf<CardsFeature>) {
    self.store = store
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    @Dependency(\.fetchesFirstValueAtOnce) var fetchesFirstValueAtOnce
    @Dependency(\.defaultDatabase) var database
    let day = calendar.startOfDay(for: now)
    _day = State(initialValue: day)
    // Window catalogs hold the main queue until their image is taken, so the task never runs.
    _headlines = State(
      initialValue: fetchesFirstValueAtOnce
        ? (try? database.read {
          CardHeadlinesRequest(cards: store.cards, day: day).fetch(
            now: now, calendar: calendar, $0)
        }) ?? [:] : [:])
    _highlights = Fetch(wrappedValue: [], HighlightsRequest(), scheduler: MainQueueScheduler())
    _holdsCards = Fetch(wrappedValue: false, HoldsCardsRequest(), scheduler: MainQueueScheduler())
  }

  var body: some View {
    SummaryContent(
      cards: cards,
      highlights: $highlights.loadError.map { .failed($0.localizedDescription) }
        ?? ($highlights.isLoading && highlights.isEmpty ? .loading : .loaded(highlights)),
      actions: SummaryCardActions(
        newCard: { store.send(.newCardButtonTapped) },
        edit: { store.send(.editCardButtonTapped(id: $0.id)) },
        delete: { store.send(.deleteCardButtonTapped(id: $0.id)) },
        moveUp: { store.send(.moveCardUp(id: $0.id)) },
        moveDown: { store.send(.moveCardDown(id: $0.id)) })
    ) { card in
      CardRow(
        card: card, headline: headlines[card.id] ?? .loading, now: date.now, calendar: calendar)
    }
    // Again when a card's spec changes, one's added, or the day does.
    .task(id: CardHeadlinesRequest(cards: store.cards, day: day)) {
      let request = CardHeadlinesRequest(cards: store.cards, day: day)
      for await headlines in request.observe(
        in: database, clock: clock, now: { [date] in date.now }, calendar: calendar)
      {
        self.headlines = headlines
      }
    }
    // Reorder Cards… (851-3210) and New Card… (⌘N, 851-3208), while Summary shows.
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Reorder Cards…", systemImage: "arrow.up.arrow.down") {
          store.send(.reorderCardsButtonTapped)
        }
        .help("Reorder Cards")
        .disabled(!store.canReorderCards)
      }
      ToolbarItem(placement: .primaryAction) {
        Button("New Card…", systemImage: "plus") {
          store.send(.newCardButtonTapped)
        }
        .keyboardShortcut("n")
        .help("New Card")
        .disabled(!store.canCreateCard)
      }
    }
    .onReceive(calendarDayChanges()) {
      day = calendar.startOfDay(for: date.now)
      Task { @MainActor in
        _ = try? await $highlights.load(
          HighlightsRequest(day: date.now), scheduler: MainQueueScheduler())
      }
    }
  }

  private var cards: SummaryLoad<[Card]> {
    if let failure = store.loadFailure { return .failed(failure) }
    // Not if it can't tell: an account without cards would load for ever.
    if store.isLoading || store.cards.isEmpty && !holdsCards && $holdsCards.loadError == nil {
      return .loading
    }
    return .loaded(Array(store.cards))
  }
}

/// Summary's card headlines (`HealthDatabase.cardHeadline`), every card's in one read, each its
/// own success or failure (851-3237). Each row following its own (`@Fetch`) ran every card again
/// after each page a first sync or backfill wrote, on the writer, holding sync up: 100 cards made
/// a backfill take 5 times as long. Observed with `throttledObservation`, they're read at most once
/// a second while sync writes, off the writer, and once more after its last page.
struct CardHeadlinesRequest: Hashable, Sendable {
  /// The cards' specs, by ID: a new order is the same request, a new spec or card a new one. A
  /// card this version can't read has no headline.
  let specs: [Card.ID: CardSpec]
  /// The day it's for, so a new day is a new request.
  let day: Date

  init(cards: some Sequence<Card>, day: Date) {
    specs = Dictionary(
      cards.compactMap { card in card.spec.map { (card.id, $0) } }, uniquingKeysWith: { $1 })
    self.day = day
  }

  /// Each card's headline, from data started by `now`.
  func fetch(now: Date, calendar: Calendar, _ db: Database) -> [Card.ID: CardRow.Headline] {
    specs.mapValues { spec in
      do {
        return .loaded(try HealthDatabase.cardHeadline(spec, now: now, calendar: calendar, db))
      } catch {
        return .failed(error.localizedDescription)
      }
    }
  }

  /// The headlines, now and again as the tables cards read change, at most once a second. A read
  /// that fails fails every card.
  func observe(
    in database: any DatabaseWriter, clock: any Clock<Duration>,
    now: @escaping @Sendable () -> Date, calendar: Calendar
  ) -> some AsyncSequence<[Card.ID: CardRow.Headline], Never> {
    let specs = specs
    return
      throttledObservation(of: HealthDatabase.cardTables, in: database, clock: clock) { db in
        self.fetch(now: now(), calendar: calendar, db)
      }
      .map { result in
        switch result {
        case .success(let headlines): headlines
        case .failure(let error): specs.mapValues { _ in .failed(error.localizedDescription) }
        }
      }
  }
}

/// Whether the local data holds the account's cards (`LilSyncEngine.holds(_:_:)`).
struct HoldsCardsRequest: FetchKeyRequest {
  func fetch(_ db: Database) throws -> Bool {
    try LilSyncEngine.holds(Card.entity, db)
  }
}

/// Summary's highlights, as of when they're fetched.
struct HighlightsRequest: FetchKeyRequest {
  /// The day it's for, so a new day is a new request.
  let day: Date

  init(day: Date = .now) {
    self.day = Calendar.current.startOfDay(for: day)
  }

  func fetch(_ db: Database) throws -> [Highlight] {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    return try HealthDatabase.highlights(now: now, calendar: calendar, db)
  }
}

/// Something Summary loads: its cards, its highlights.
enum SummaryLoad<Value> {
  case loading
  case loaded(Value)
  case failed(String)
}

/// What Summary's New Card… and a row's context menu do (851-3208, 851-3210).
struct SummaryCardActions {
  var newCard: () -> Void
  var edit: (Card) -> Void
  var delete: (Card) -> Void
  var moveUp: (Card) -> Void
  var moveDown: (Card) -> Void
}

/// What Summary shows, however it got it: the cards, a row each from `row`, then the highlights.
struct SummaryContent<Row: View>: View {
  let cards: SummaryLoad<[Card]>
  var highlights: SummaryLoad<[Highlight]> = .loaded([])
  /// New Card… in the empty section, and each row's Edit…, Move Up, Move Down and Delete….
  /// Without them, none of these shows.
  var actions: SummaryCardActions?
  /// A card's row, with its headline.
  @ViewBuilder let row: (Card) -> Row
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  var body: some View {
    // A grouped form on its own background, as Metric Detail is (851-2989): a section of the
    // cards, a row each, then the highlights.
    Form {
      Section {
        cardsSection
      }
      Section {
        highlightsSection
      } header: {
        Text("Highlights")
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutAnchor("Highlights")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Summary")
  }

  @ViewBuilder private var cardsSection: some View {
    switch cards {
    case .failed(let reason):
      Label("Couldn't load your cards: \(reason)", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
    case .loading:
      // The welcome seed's rows, as tall as they'll be with data (851-3092), so the highlights
      // don't move when the cards arrive: what a new account has, and an existing one most
      // likely.
      ForEach(Card.welcomeSeed) { card in
        NavigationLink(value: PushedPage.card(card.id)) {
          CardRow(card: card, headline: .loading, now: now, calendar: calendar)
        }
      }
    case .loaded(let cards) where cards.isEmpty:
      ContentUnavailableView {
        Label("No Cards", systemImage: "rectangle.stack")
      } description: {
        Text("Cards you add show here.")
      } actions: {
        if let actions {
          Button("New Card…", action: actions.newCard)
        }
      }
      // A form's row would otherwise give it only its ideal width, off center.
      .frame(maxWidth: .infinity)
    case .loaded(let cards):
      // Every card opens its page (851-3207), a later version's too, so every row has the
      // form's chevron and their columns line up.
      ForEach(cards) { card in
        NavigationLink(value: PushedPage.card(card.id)) {
          row(card)
        }
        .contextMenu {
          if let actions {
            // A later version's card can't be edited here, only deleted and moved.
            Button("Edit…") { actions.edit(card) }
              .disabled(card.spec == nil)
            Divider()
            Button("Move Up") { actions.moveUp(card) }
              .disabled(card.id == cards.first?.id)
            Button("Move Down") { actions.moveDown(card) }
              .disabled(card.id == cards.last?.id)
            Divider()
            Button("Delete…", role: .destructive) { actions.delete(card) }
          }
        }
      }
    // No `onMove`: a grouped form isn't a table on the Mac, so its rows can't be dragged
    // (851-3210). Reorder Cards… (the toolbar) drags them in a list instead.
    }
  }

  @ViewBuilder private var highlightsSection: some View {
    switch highlights {
    case .loading:
      DelayedProgressView()
        .frame(maxWidth: .infinity, minHeight: 120)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load Highlights", systemImage: "exclamationmark.triangle",
        description: Text(reason)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let highlights) where highlights.isEmpty:
      Text(
        "Highlights appear once there are a couple of weeks of steps, energy, heart or weight data to compare."
      )
      .foregroundStyle(.secondary)
    case .loaded(let highlights):
      ForEach(highlights) { highlight in
        if let type = HealthCatalog.type(id: highlight.typeID) {
          NavigationLink(value: PushedPage.metric(highlight.typeID)) {
            HighlightRow(highlight: highlight, type: type)
          }
        }
      }
    }
  }
}
