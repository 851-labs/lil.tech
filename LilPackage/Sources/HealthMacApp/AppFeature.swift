public import ComposableArchitecture
import Foundation
public import HealthCatalog
import HealthDatabase
public import LilAuth
public import LilSync
import SQLiteData

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
    /// Account settings, in the Settings window. Kept here rather than presented, so the window
    /// works whether or not the main one is open, and an export keeps going when it closes.
    public var account = AccountFeature.State()
    /// Pins from before they synced, moved up when sync starts (`movePinsUp`).
    @Shared(.summaryPins) var localPins: [String]

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
    case account(AccountFeature.Action)
    case signOutButtonTapped
    case summary(SummaryFeature.Action)
    case syncStatusChanged(SyncStatus)
    case localPinsMovedUp([String])
    case task
  }

  enum CancelID {
    /// Pulling (`SyncClient.run`), restarted by Try Again.
    case pull
    /// Everything that runs while signed in.
    case sync
  }

  @Dependency(\.auth) var auth
  @Dependency(\.authSessions) var authSessions
  @Dependency(\.blobCache) var blobCache
  @Dependency(\.defaultDatabase) var database
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
    Scope(\.account, action: \.account) {
      AccountFeature()
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
          return wasSignedIn == true ? .none : startSync(localPins: state.localPins)
        }
        // The next account starts afresh.
        state.signIn = SignInFeature.State()
        state.selection = .summary
        state.searchText = ""
        state.syncStatus = .idle
        state.account = AccountFeature.State()
        // Pins are the account's choice, like its data, and leave with it.
        state.summary = SummaryFeature.State()
        state.$localPins.withLock { $0 = [] }
        // The account's health data leaves the Mac with it. Also when the app opens signed out,
        // in case it quit before it was done. Removing waits for a pull being cancelled to stop
        // (`LilSyncEngine.removeLocalData()`).
        return .merge(
          .cancel(id: CancelID.pull),
          .cancel(id: CancelID.sync),
          .cancel(id: SummaryFeature.CancelID.write),
          // What the Settings window started for the account stops with it.
          AccountFeature.cancel(),
          .run { [sync, blobCache] send in
            // First, so it's done even if the database can't be.
            await blobCache.removeAll()
            do {
              try await sync.removeLocalData()
            } catch {
              reportIssue(error)
            }
            // Only now, so a scripted run's sign-in doesn't sync into data being removed.
            await send(.signIn(.readyToSignIn))
          }
        )

      case .signOutButtonTapped:
        // The session's updates say when it's done.
        return .run { [auth] _ in await auth.signOut() }

      case .account:
        return .none

      case .summary:
        return .none

      case .syncStatusChanged(let status):
        state.syncStatus = status
        return .none

      case .localPinsMovedUp(let moved):
        // Only those moved: any pinned meanwhile on a Mac without sync stay for next time.
        state.$localPins.withLock { local in local.removeAll { moved.contains($0) } }
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

  /// Moves this Mac's pins from before they synced up to the account (851-2641): through sync's
  /// queue, so they show at once, survive the bootstrap that adding pins brings, and reach the
  /// server with the first sync. Any the account has already stay first. Cleared once written.
  private func movePinsUp(_ local: [String]) -> Effect<Action> {
    .run { [database, sync] send in
      let synced = try await database.read { try HealthDatabase.summaryPins($0) }
      let pins = synced + local.filter { !synced.contains($0) }
      try await sync.push(HealthDatabase.pinMutations(from: synced, to: pins))
      await send(.localPinsMovedUp(local))
    } catch: { error, _ in
      guard !(error is CancellationError) else { return }
      reportIssue(error)
    }
    .cancellable(id: SummaryFeature.CancelID.write)
  }

  /// Pulls, follows live notices of new changes, and reports the status, until signed out.
  private func startSync(localPins: [String]) -> Effect<Action> {
    .merge(
      localPins.isEmpty ? .none : movePinsUp(localPins),
      pull(),
      .run { [sync, authSessions] _ in
        await sync.listen(authSessions.apiAuthentication)
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
