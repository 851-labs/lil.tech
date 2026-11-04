public import ComposableArchitecture
import Dependencies
import HealthCardStore
import HealthCards
import HealthKitAccess
import HealthUI
import LilUI
public import SwiftUI

/// Summary (851-3211, docs/decisions/cards.md, UI › iPhone): the iPhone's root screen once it's set
/// up, and its first for browsing data. The account's cards, a row each in their order, drawn as
/// the Mac's Summary draws them (`CardRow`), each computed from this iPhone's HealthKit
/// (`healthKitCards`). Sync Status is a row at the top while an upload is under way or needs the
/// person, and a toolbar button otherwise; Settings is a toolbar button. It runs the cards' and the
/// upload status's tasks while it shows.
public struct SummaryView: View {
  let cards: StoreOf<CardsFeature>
  @Bindable var syncStatus: StoreOf<SyncStatusFeature>
  /// Today, so headlines move at midnight: `nil` until Summary shows, so making the view reads no
  /// dependency (the app makes it again whenever its state changes).
  @State private var day: Date?
  /// Bumped when the app comes back to the front, so every row runs its card again: HealthKit may
  /// have new data.
  @State private var generation = 0
  @State private var wasInBackground = false
  @Environment(\.scenePhase) private var scenePhase
  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar

  public init(cards: StoreOf<CardsFeature>, syncStatus: StoreOf<SyncStatusFeature>) {
    self.cards = cards
    self.syncStatus = syncStatus
  }

  public var body: some View {
    NavigationStack {
      SummaryContent(
        cards: SummaryLoad(cards.state), syncStatus: syncStatus.status,
        showSettings: { syncStatus.send(.settingsPresented(true)) }
      ) { card in
        CardPreview(card: card, day: day, generation: generation)
      }
      .navigationDestination(for: SummaryPage.self) { page in
        switch page {
        case .syncStatus:
          SyncStatusView(store: syncStatus)
        }
      }
      .sheet(isPresented: $syncStatus.isShowingSettings.sending(\.settingsPresented)) {
        SettingsSheet(store: syncStatus)
      }
    }
    .task {
      day = calendar.startOfDay(for: date.now)
      await cards.send(.task).finish()
    }
    .task { await syncStatus.send(.task).finish() }
    .onReceive(calendarDayChanges()) {
      day = calendar.startOfDay(for: date.now)
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background:
        wasInBackground = true
      case .active where wasInBackground:
        wasInBackground = false
        day = calendar.startOfDay(for: date.now)
        generation += 1
      default:
        break
      }
    }
  }
}

/// What Summary pushes.
enum SummaryPage: Hashable {
  case syncStatus
}

/// Summary's cards, as `CardsFeature` has them.
enum SummaryLoad: Equatable {
  /// Not read yet, or not pulled once since signing in: the welcome seed's rows, loading.
  case loading
  case loaded([Card])
  case failed(String)

  init(_ cards: CardsFeature.State) {
    if let failure = cards.loadFailure {
      self = .failed(failure)
    } else if cards.isLoading {
      self = .loading
    } else {
      self = .loaded(Array(cards.cards))
    }
  }
}

/// What Summary shows, however it got it: the upload's status, then the cards, a row each from
/// `row`.
struct SummaryContent<Row: View>: View {
  let cards: SummaryLoad
  let syncStatus: SyncStatusFeature.State.Status
  var showSettings: () -> Void = {}
  /// A card's row, with its headline.
  @ViewBuilder let row: (Card) -> Row
  var body: some View {
    List {
      if syncStatus.isShownAsRow {
        Section {
          NavigationLink(value: SummaryPage.syncStatus) {
            SyncStatusRow(status: syncStatus)
          }
        }
      }
      Section {
        cardsSection
      }
    }
    .navigationTitle("Summary")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if !syncStatus.isShownAsRow {
          NavigationLink(value: SummaryPage.syncStatus) {
            Label("Sync Status", systemImage: syncStatus.toolbarSymbol)
          }
        }
        Button(action: showSettings) {
          Label("Settings", systemImage: "gearshape")
        }
      }
    }
  }

  @ViewBuilder private var cardsSection: some View {
    switch cards {
    case .failed(let reason):
      Label("Couldn't load your cards: \(reason)", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
    case .loading:
      // The welcome seed's rows, as tall as they'll be with data (851-3092): what a new account
      // has, and an existing one most likely.
      // They show no date, so they read no dependency, which this view would read whenever the
      // app's state changes.
      ForEach(Card.welcomeSeed) { card in
        CardRow(loading: card)
      }
    case .loaded(let cards) where cards.isEmpty:
      ContentUnavailableView {
        Label("No Cards", systemImage: "rectangle.stack")
      } description: {
        Text("Cards you add show here.")
      }
    case .loaded(let cards):
      ForEach(cards) { card in
        row(card)
      }
    }
  }
}

/// A card's row, its headline run on this iPhone's HealthKit: again when the card's query changes,
/// at midnight, and when the app comes back to the front (`generation`). The last headline stays
/// while the next runs, so a row only reads "–" before its first.
struct CardPreview: View {
  let card: Card
  /// `nil` until Summary knows it: the row waits.
  let day: Date?
  let generation: Int
  @State private var headline: CardRow.Headline = .loading
  @Dependency(\.healthKitCards) private var healthKitCards
  @Dependency(\.date) private var date
  @Dependency(\.calendar) private var calendar

  var body: some View {
    CardRow(card: card, headline: headline, now: date.now, calendar: calendar)
      .task(id: Run(spec: card.spec, day: day, generation: generation)) {
        guard let spec = card.spec, day != nil else { return }
        do {
          let result = try await Self.headline(
            of: spec, in: healthKitCards, now: date.now, calendar: calendar)
          guard !Task.isCancelled else { return }
          headline = .loaded(result)
        } catch {
          guard !Task.isCancelled, !(error is CancellationError) else { return }
          headline = .failed(error.localizedDescription)
        }
      }
  }

  /// What makes a row run its card again.
  private struct Run: Equatable {
    var spec: CardSpec?
    var day: Date?
    var generation: Int
  }

  /// Off the main actor: the engine weighs and aggregates the readings HealthKit returns.
  @concurrent
  private static func headline(
    of spec: CardSpec, in cards: HealthKitCards, now: Date, calendar: Calendar
  ) async throws -> CardHeadline? {
    try await cards.headline(spec, now, calendar)
  }
}

/// The upload's status as Summary's row: its symbol and title, and its progress, or what it needs.
struct SyncStatusRow: View {
  let status: SyncStatusFeature.State.Status

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SyncStatusLabel(status: status)
        .font(.headline)
      switch status {
      case .uploading(_, _, let records, let totalRecords),
        .paused(_, _, let records, let totalRecords):
        UploadCounts(records: records, totalRecords: totalRecords)
      default:
        if let message = status.message {
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 4)
  }
}

extension SyncStatusFeature.State.Status {
  /// Whether Summary shows the status as a row at the top: while an upload is under way, or it
  /// needs the person (consent, Health access, a failure). Otherwise it's a toolbar button.
  var isShownAsRow: Bool {
    switch self {
    case .loading, .upToDate: false
    case .needsConsent, .needsHealthAccess, .offline, .storageFull, .failed, .uploading, .paused:
      true
    }
  }

  /// The toolbar button's symbol, when it isn't a row.
  var toolbarSymbol: String {
    switch self {
    case .upToDate: "checkmark.icloud"
    default: "icloud"
    }
  }
}
