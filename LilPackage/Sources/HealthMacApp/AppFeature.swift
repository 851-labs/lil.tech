public import ComposableArchitecture
import Foundation
public import HealthCatalog
public import LilAuth
public import LilSync

/// lil health on the Mac: sign in, then iPad Health's layout, a sidebar of Summary and the
/// Health categories beside what's selected. While signed in, it syncs the account's health data
/// into the local database; signing out deletes it.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    /// `nil` until the stored session has been checked.
    public var isSignedIn: Bool?
    public var signIn = SignInFeature.State()
    public var selection: SidebarItem? = .summary
    public var searchText = ""
    /// Shown in the sidebar's footer.
    public var syncStatus: SyncStatus
    public var summary: SummaryFeature.State

    public init(
      isSignedIn: Bool? = nil, selection: SidebarItem? = .summary, searchText: String = "",
      syncStatus: SyncStatus = .idle, summary: SummaryFeature.State = SummaryFeature.State()
    ) {
      self.isSignedIn = isSignedIn
      self.selection = selection
      self.searchText = searchText
      self.syncStatus = syncStatus
      self.summary = summary
    }

    /// The search, without surrounding spaces.
    public var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// The data types whose names match the search, by category order then name. Every type in
    /// the catalog, whatever iOS version added it: the Mac shows what's synced. Characteristics,
    /// which have no category, aren't data to browse.
    public var searchResults: [HealthDataType] {
      guard !query.isEmpty else { return [] }
      return HealthCategory.allCases.flatMap { category in
        HealthCatalog.all
          .filter { $0.category == category && $0.name.localizedStandardContains(query) }
          .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case retrySyncButtonTapped
    case signedInChanged(Bool)
    case signIn(SignInFeature.Action)
    case signOutButtonTapped
    case summary(SummaryFeature.Action)
    case syncStatusChanged(SyncStatus)
    case task
  }

  enum CancelID {
    /// Pulling (`SyncClient.run`), restarted by Try Again.
    case pull
    /// Everything that runs while signed in.
    case sync
  }

  /// The session ended between handing a live connection a token and asking for it.
  struct SignedOut: Error {}

  @Dependency(\.auth) var auth
  @Dependency(\.authSessions) var authSessions
  @Dependency(\.blobCache) var blobCache
  @Dependency(\.sync) var sync

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
      .onChange(of: \.query) { _, state in
        // A type found by search goes when the search does: its category takes its place.
        if state.query.isEmpty, case .dataType(let id) = state.selection {
          state.selection =
            HealthCatalog.type(id: id)?.category.map(SidebarItem.category) ?? .summary
        }
        return .none
      }
    Scope(\.signIn, action: \.signIn) {
      SignInFeature()
    }
    Scope(\.summary, action: \.summary) {
      SummaryFeature()
    }
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .retrySyncButtonTapped:
        // A new pull right away: asking the running one (`syncNow`) wouldn't cut its backoff
        // after a failure short.
        return pull()

      case .signedInChanged(let isSignedIn):
        let wasSignedIn = state.isSignedIn
        state.isSignedIn = isSignedIn
        if isSignedIn {
          return wasSignedIn == true ? .none : startSync()
        }
        // The next account starts afresh.
        state.signIn = SignInFeature.State()
        state.selection = .summary
        state.searchText = ""
        state.syncStatus = .idle
        // Pins are the account's choice, like its data.
        state.summary.isEditing = false
        state.summary.$pins.withLock { $0 = [] }
        // The account's health data leaves the Mac with it. Also when the app opens signed out,
        // in case it quit before it was done. Removing waits for a pull being cancelled to stop
        // (`LilSyncEngine.removeLocalData()`).
        return .merge(
          .cancel(id: CancelID.pull),
          .cancel(id: CancelID.sync),
          .run { [sync, blobCache] _ in
            // First, so it's done even if the database can't be.
            await blobCache.removeAll()
            try await sync.removeLocalData()
          } catch: { error, _ in
            reportIssue(error)
          }
        )

      case .signOutButtonTapped:
        // The session's updates say when it's done.
        return .run { [auth] _ in await auth.signOut() }

      case .summary:
        return .none

      case .syncStatusChanged(let status):
        state.syncStatus = status
        return .none

      case .signIn:
        // The session's updates say when signing in worked.
        return .none

      case .task:
        return .run { [auth] send in
          for await isSignedIn in await auth.signedInUpdates() {
            await send(.signedInChanged(isSignedIn))
          }
        }
      }
    }
  }

  /// Pulls, follows live notices of new changes, and reports the status, until signed out.
  private func startSync() -> Effect<Action> {
    .merge(
      pull(),
      .run { [sync, authSessions] _ in
        await sync.listen {
          guard let token = try await authSessions.accessToken() else { throw SignedOut() }
          return token
        }
      }
      .cancellable(id: CancelID.sync),
      .run { [sync] send in
        for await status in await sync.status() {
          await send(.syncStatusChanged(status))
        }
      }
      .cancellable(id: CancelID.sync)
    )
  }

  private func pull() -> Effect<Action> {
    .run { [sync] _ in await sync.run() }
      .cancellable(id: CancelID.pull, cancelInFlight: true)
  }
}

/// What the sidebar can select: Summary, a category to browse, or a data type found by search.
public enum SidebarItem: Hashable, Sendable {
  case summary
  case category(HealthCategory)
  case dataType(String)
}
