public import ComposableArchitecture
import Foundation
public import HealthAgentAccess
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
    /// The metrics opened in Summary's or a category's stack, as type IDs. Emptied when the
    /// selection changes, so one's metric doesn't show under another.
    public var metricPath: [String] = []
    public var searchText = ""
    /// Shown in the sidebar's footer, while `syncFooter` shows it.
    public var syncStatus: SyncStatus
    /// Whether the sidebar shows its sync footer (851-2991).
    public var syncFooter: SyncFooterVisibility
    /// Account settings, in the Settings window. Kept here rather than presented, so the window
    /// works whether or not the main one is open, and an export keeps going when it closes.
    public var account = AccountFeature.State()
    /// Command-line and agent access, in the Settings window's Agents pane.
    public var agentAccess = AgentAccessFeature.State()
    /// Remote agents connected to the account, in the Agents pane. Kept here, like `account`.
    public var connectedAgents = ConnectedAgentsFeature.State()
    public init(
      isSignedIn: Bool? = nil, selection: SidebarItem? = .summary, metricPath: [String] = [],
      searchText: String = "", syncStatus: SyncStatus = .idle
    ) {
      self.isSignedIn = isSignedIn
      self.selection = selection
      self.metricPath = metricPath
      self.searchText = searchText
      self.syncStatus = syncStatus
      // As the status shows once it has lasted, for previews and snapshots: signing in starts
      // hidden (`signedInChanged`).
      self.syncFooter = SyncFooterVisibility(settledFor: syncStatus)
    }

    /// The search, without surrounding spaces.
    public var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// The data types whose names match the search, by category order then name
    /// (`HealthPage.browsableTypes`).
    public var searchResults: [HealthDataType] {
      guard !query.isEmpty else { return [] }
      return HealthPage.browsableTypes.filter { $0.name.localizedStandardContains(query) }
    }
  }

  public enum Action: BindableAction {
    /// An app action an intent asked for (`HealthAppActions`), with how to answer it.
    case appActionRequested(HealthAppActionRequest)
    case binding(BindingAction<State>)
    /// Requests from the command line (`lil-health open`, `sync`, `export`) the app claimed from
    /// `AgentAccess.sqlite`, to perform through `HealthAppActions` (851-2895).
    case commandLineActionsClaimed([AgentActionRequest])
    case retrySyncButtonTapped
    case signedInChanged(Bool)
    case signIn(SignInFeature.Action)
    case account(AccountFeature.Action)
    case agentAccess(AgentAccessFeature.Action)
    case connectedAgents(ConnectedAgentsFeature.Action)
    case signOutButtonTapped
    /// A new pull for the Sync app action, as Try Again starts one. Sent once the action is
    /// watching the status, so it can't miss how the pull ends.
    case syncRestarted
    case syncStatusChanged(SyncStatus)
    /// Sync has gone `syncFooterDelay` without being up to date: the footer shows.
    case syncFooterDelayElapsed
    /// A stack's navigation changed its metrics: a card clicked, or Back. The stack says which
    /// selection it shows, so one that's going away (as the selection changes) can't empty the
    /// path the next one opens with.
    case metricPathChanged([String], selection: SidebarItem?)
    /// Shows a page, as the sidebar and a metric's card do: the window's part is the intent's.
    case pageOpened(HealthPage)
    case task
  }

  enum CancelID {
    /// Pulling (`SyncClient.run`), restarted by Try Again.
    case pull
    /// Everything that runs while signed in.
    case sync
    /// Waiting to show the sync footer (`syncFooterDelay`).
    case syncFooterDelay
  }

  /// How long sync goes without being up to date before the sidebar's footer shows it
  /// (851-2991). Everyday syncs are a page, done in well under a second: once up to date, they go
  /// from up to date straight to up to date again (`.syncing` only follows a page with more after
  /// it), and the one at launch from "not run yet" to up to date. A failure the first retry fixes,
  /// about a second later (e.g. offline for a moment after waking), is as brief. Two seconds
  /// leaves room for a slow network at launch, so none of them flash the footer, while a
  /// catch-up, a first sync or a failure that lasts still says so soon.
  static let syncFooterDelay = Duration.seconds(2)

  @Dependency(\.agentAccess) var agentAccess
  @Dependency(\.auth) var auth
  @Dependency(\.authSessions) var authSessions
  @Dependency(\.blobCache) var blobCache
  @Dependency(\.continuousClock) var clock
  @Dependency(\.defaultAppStorage) var defaultAppStorage
  @Dependency(\.healthAppActions) var healthAppActions
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
      .onChange(of: \.selection) { _, state in
        state.metricPath = []
        return .none
      }
    Scope(\.signIn, action: \.signIn) {
      SignInFeature()
    }
    Scope(\.account, action: \.account) {
      AccountFeature()
    }
    Scope(\.agentAccess, action: \.agentAccess) {
      AgentAccessFeature()
    }
    Scope(\.connectedAgents, action: \.connectedAgents) {
      ConnectedAgentsFeature()
    }
    Reduce { state, action in
      switch action {
      case .appActionRequested(let request):
        switch request.action {
        case .open(let page):
          return .run { send in
            await send(.pageOpened(page))
            request.finish(.success(.done))
          }
        case .sync:
          return syncForAppAction(request)
        case .export(let folder):
          // The export Settings shows, so it's one at a time with an export started there, and
          // signing out stops it (`AccountFeature.cancel()`).
          return .send(.account(.dataExport(.exportToFolderRequested(folder, request))))
        }

      case .binding:
        return .none

      case .commandLineActionsClaimed(let requests):
        return .merge(requests.map(performCommandLineAction))

      case .retrySyncButtonTapped:
        // A new pull right away: asking the running one (`syncNow`) wouldn't cut its backoff
        // after a failure short.
        return pull()

      case .signedInChanged(let isSignedIn):
        let wasSignedIn = state.isSignedIn
        state.isSignedIn = isSignedIn
        if isSignedIn {
          guard wasSignedIn != true else { return .none }
          // Until the first pull has run for a while, or needs attention.
          state.syncFooter = .hidden
          return startSync()
        }
        // The next account starts afresh.
        state.signIn = SignInFeature.State()
        state.selection = .summary
        state.metricPath = []
        state.searchText = ""
        state.syncStatus = .idle
        state.syncFooter = .hidden
        state.account = AccountFeature.State()
        state.agentAccess = AgentAccessFeature.State()
        state.connectedAgents = ConnectedAgentsFeature.State()
        // The account's health data leaves the Mac with it. Also when the app opens signed out,
        // in case it quit before it was done. Removing waits for a pull being cancelled to stop
        // (`LilSyncEngine.removeLocalData()`).
        return .merge(
          .cancel(id: CancelID.pull),
          .cancel(id: CancelID.sync),
          .cancel(id: CancelID.syncFooterDelay),
          // What the Settings window started for the account stops with it.
          AccountFeature.cancel(),
          ConnectedAgentsFeature.cancel(),
          .run {
            [agentAccess, sync, blobCache, defaults = UncheckedSendable(defaultAppStorage)] send in
            // First, so it's done even if the database can't be.
            await blobCache.removeAll()
            // Summary's pins from before they synced, which a Mac may still have though pins
            // are retired (851-2990).
            defaults.value.removeObject(forKey: "summaryPins")
            // Whether tools and agents may read the account's data was its choice, and their log
            // is about its data: the next account decides for itself.
            do {
              try await agentAccess.reset()
            } catch {
              reportIssue(error)
            }
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

      case .agentAccess:
        return .none

      case .connectedAgents:
        return .none

      case .syncRestarted:
        return pull()

      case .syncStatusChanged(let status):
        state.syncStatus = status
        switch status {
        case .upToDate:
          state.syncFooter = .hidden
          return .cancel(id: CancelID.syncFooterDelay)
        case .idle, .syncing, .bootstrapping, .offline, .failed:
          // Shown already (e.g. catching up after a first sync, or after a failure), or waiting:
          // the wait isn't started again by each page or retry.
          guard state.syncFooter == .hidden else { return .none }
          state.syncFooter = .delayed
          return .run { [clock] send in
            try await clock.sleep(for: Self.syncFooterDelay)
            await send(.syncFooterDelayElapsed)
          }
          .cancellable(id: CancelID.syncFooterDelay, cancelInFlight: true)
        }

      case .syncFooterDelayElapsed:
        guard state.syncFooter == .delayed else { return .none }
        state.syncFooter = .shown
        return .none

      case .metricPathChanged(let path, let selection):
        guard selection == state.selection else { return .none }
        state.metricPath = path
        return .none

      case .pageOpened(let page):
        state.searchText = ""
        state.metricPath = []
        switch page.kind {
        case .summary:
          state.selection = .summary
        case .healthDetails:
          state.selection = .healthDetails
        case .category(let category):
          state.selection = .category(category)
        case .dataType(let type):
          // As if its row were clicked in its category.
          state.selection = type.category.map(SidebarItem.category) ?? .summary
          state.metricPath = [type.id]
        }
        return .none

      case .signIn:
        // The session's updates say when signing in worked.
        return .none

      case .task:
        return .merge(
          .run { [auth] send in
            for await isSignedIn in await auth.signedInUpdates() {
              await send(.signedInChanged(isSignedIn))
            }
          },
          claimCommandLineActions()
        )
      }
    }
  }

  /// Pulls, follows live notices of new changes, and reports the status, until signed out.
  private func startSync() -> Effect<Action> {
    .merge(
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
      .cancellable(id: CancelID.sync),
      // App actions are served while signed in: signing out ends the stream, which fails those
      // still waiting.
      .run { [healthAppActions] send in
        for await request in healthAppActions.requests() {
          await send(.appActionRequested(request))
        }
      }
      .cancellable(id: CancelID.sync)
    )
  }

  /// The command line's requests (851-2895): claimed at launch, signed in or not, and each time a
  /// command signals. Claiming checks access is still on, so a request made just before it was
  /// turned off fails instead (`AgentAccessStore.claimActions`).
  private func claimCommandLineActions() -> Effect<Action> {
    .run { [agentAccess] send in
      for await _ in agentAccess.actionsRequested() {
        do {
          let requests = try await agentAccess.claimActions()
          if !requests.isEmpty { await send(.commandLineActionsClaimed(requests)) }
        } catch {
          reportIssue(error)
        }
      }
    }
  }

  /// Performs a request from the command line as the intents' are, through `HealthAppActions`:
  /// it waits for sign-in after launch, then fails with "Sign in to lil health first.". Writes
  /// the outcome for the command to read. Not cancelled by signing out: that fails the action,
  /// and the failure is written.
  private func performCommandLineAction(_ request: AgentActionRequest) -> Effect<Action> {
    .run { [agentAccess, healthAppActions, clock] _ in
      let outcome: AgentActionOutcome
      do {
        let action = try HealthAppAction(request.action)
        // Forward first, then the page, as the intent does.
        if case .open = action { await agentAccess.bringAppForward() }
        outcome = .ok(AgentActionResult(try await healthAppActions.perform(action, { _ in })))
      } catch {
        outcome = .failed(AgentActionFailure(error))
      }
      // Tried again, since the command waits on it: a request left claimed without an outcome
      // reads as running for as long as the app runs.
      for attempt in 1...3 {
        do {
          return try await agentAccess.finishAction(request.id, outcome)
        } catch {
          guard attempt < 3 else { return reportIssue(error) }
          try? await clock.sleep(for: .seconds(1))
        }
      }
    }
  }

  /// Sync, for an app action (851-2893): a new pull, as Try Again, unless one is running, then
  /// the first status that says how it ended, or `.stillSyncing` after `HealthAppActions.syncWait`.
  /// Stops with the account, which fails the request (`HealthAppActionError.signedOut`).
  private func syncForAppAction(_ request: HealthAppActionRequest) -> Effect<Action> {
    .run { [sync, clock] send in
      typealias Answer = Result<HealthAppActionResult, any Error>
      let result = await withTaskGroup(of: Answer?.self, returning: Answer?.self) { group in
        group.addTask { () -> Answer? in
          var statuses = await sync.status().makeAsyncIterator()
          // The status from before: only what comes after it answers. A failure the same as the
          // last one's is announced again (`LilSyncEngine`).
          switch await statuses.next() {
          case .idle, .syncing, .bootstrapping:
            // A pull is running (the first since signing in, a catch-up, a bootstrap): its end
            // is the answer. Restarting it would throw away a bootstrap's progress.
            break
          case .upToDate, .failed, .offline, nil:
            // Waiting for the next pull, or backing off after a failure: a new one now.
            await send(.syncRestarted)
          }
          while let status = await statuses.next() {
            switch status {
            case .upToDate(let date): return .success(.synced(at: date))
            case .failed(let message): return .failure(HealthAppActionError.syncFailed(message))
            case .offline: return .failure(HealthAppActionError.offline)
            case .idle, .syncing, .bootstrapping: continue
            }
          }
          return nil
        }
        group.addTask { () -> Answer? in
          do {
            try await clock.sleep(for: HealthAppActions.syncWait)
            return .success(.stillSyncing)
          } catch {
            return nil
          }
        }
        // The first answer: the status stream ending (or being cancelled) gives none.
        for await answer in group {
          guard let answer else { continue }
          group.cancelAll()
          return answer
        }
        return nil
      }
      // Cancelled by signing out: the request fails as the stream of requests ends.
      guard let result, !Task.isCancelled else { return }
      request.finish(result)
    }
    .cancellable(id: CancelID.sync)
  }

  private func pull() -> Effect<Action> {
    .run { [sync] _ in await sync.run() }
      .cancellable(id: CancelID.pull, cancelInFlight: true)
  }
}

/// Whether the sidebar shows its sync footer (851-2991): not when everything is up to date, when
/// it would only say so. It shows a first sync, a catch-up, a failure and being offline, once
/// they have lasted `AppFeature.syncFooterDelay`, and until sync is up to date again.
public enum SyncFooterVisibility: Equatable, Sendable {
  case hidden
  /// Not up to date, and shows if it still isn't after `AppFeature.syncFooterDelay`.
  case delayed
  case shown

  /// How a status shows once it has lasted.
  init(settledFor status: SyncStatus) {
    switch status {
    case .upToDate: self = .hidden
    case .idle, .syncing, .bootstrapping, .offline, .failed: self = .shown
    }
  }
}

/// What the sidebar can select: Summary, Health Details, a category to browse, or a data type
/// found by search.
public enum SidebarItem: Hashable, Sendable {
  case summary
  case healthDetails
  case category(HealthCategory)
  case dataType(String)
}
