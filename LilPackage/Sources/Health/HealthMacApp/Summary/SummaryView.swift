import ComposableArchitecture
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
/// the cards as `CardsFeature` reads them, and each card's headline and the highlights in the
/// local database as sync changes it.
struct SummaryView: View {
  let store: StoreOf<CardsFeature>
  @Fetch private var highlights: [Highlight]
  /// Whether the local data holds the cards: until a first pull, or an upgraded Mac's catch-up of
  /// them, brings them, no cards isn't an empty Summary (docs/decisions/cards.md, The welcome
  /// seed).
  @Fetch private var holdsCards = false
  /// Today, so headlines and highlights move at midnight, even if nothing syncs.
  @State private var day: Date
  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar

  init(store: StoreOf<CardsFeature>) {
    self.store = store
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    _day = State(initialValue: calendar.startOfDay(for: now))
    _highlights = Fetch(wrappedValue: [], HighlightsRequest(), scheduler: MainQueueScheduler())
    _holdsCards = Fetch(wrappedValue: false, HoldsCardsRequest(), scheduler: MainQueueScheduler())
  }

  var body: some View {
    SummaryContent(
      cards: cards,
      highlights: $highlights.loadError.map { .failed($0.localizedDescription) }
        ?? ($highlights.isLoading && highlights.isEmpty ? .loading : .loaded(highlights))
    ) { card in
      CardPreview(card: card, day: day)
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

/// A card's row, with its headline from the local database, followed as sync changes it.
struct CardPreview: View {
  let card: Card
  @Fetch private var headline: CardHeadlineResult?
  /// From dependencies, so snapshot catalogs fix them (`previewNow`, `previewCalendar`).
  @Dependency(\.date.now) private var now
  @Dependency(\.calendar) private var calendar

  init(card: Card, day: Date) {
    self.card = card
    if let spec = card.spec {
      _headline = Fetch(
        wrappedValue: nil, CardHeadlineRequest(spec: spec, day: day),
        scheduler: MainQueueScheduler())
    } else {
      _headline = Fetch(wrappedValue: nil)
    }
  }

  var body: some View {
    CardRow(card: card, headline: state, now: now, calendar: calendar)
  }

  private var state: CardRow.Headline {
    if let error = $headline.loadError { return .failed(error.localizedDescription) }
    guard let headline else { return .loading }
    return .loaded(headline.headline)
  }
}

/// A card's headline, once fetched: `nil` for No Data.
struct CardHeadlineResult: Equatable, Sendable {
  var headline: CardHeadline?
}

/// What a card's Summary row shows (`HealthDatabase.cardHeadline`), as of when it's fetched.
struct CardHeadlineRequest: FetchKeyRequest {
  let spec: CardSpec
  /// The day it's for, so a new day is a new request.
  let day: Date

  func fetch(_ db: Database) throws -> CardHeadlineResult? {
    // The dependencies where the fetch started (SQLiteData passes them on), so snapshot
    // catalogs fix them.
    @Dependency(\.date.now) var now
    @Dependency(\.calendar) var calendar
    return CardHeadlineResult(
      headline: try HealthDatabase.cardHeadline(spec, now: now, calendar: calendar, db))
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

/// What Summary shows, however it got it: the cards, a row each from `row`, then the highlights.
struct SummaryContent<Row: View>: View {
  let cards: SummaryLoad<[Card]>
  var highlights: SummaryLoad<[Highlight]> = .loaded([])
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
      ContentUnavailableView(
        "No Cards", systemImage: "rectangle.stack",
        description: Text("Cards you add show here.")
      )
      // A form's row would otherwise give it only its ideal width, off center.
      .frame(maxWidth: .infinity)
    case .loaded(let cards):
      // Every card opens its page (851-3207), a later version's too, so every row has the
      // form's chevron and their columns line up.
      ForEach(cards) { card in
        NavigationLink(value: PushedPage.card(card.id)) {
          row(card)
        }
      }
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

extension Card {
  /// The welcome seed's cards, as an account has them once synced: Summary's rows while its cards
  /// load.
  static let welcomeSeed: [Card] = HealthCards.welcomeSeed.map {
    Card(
      id: $0.id, spec: $0.spec, position: $0.position, createdAt: 0, updatedAt: 0, seed: $0.seed)
  }
}
