import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthCatalog
import HealthDatabase
import LilAuth
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthMacApp

@Suite(.dependencies)
@MainActor
struct AppFeatureTests {
  @Test
  func followsTheSessionAndStartsAfreshAfterSigningOut() async {
    let (updates, continuation) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = {}
      $0.auth.signedInUpdates = { updates }
      $0.sync = .constant(.idle)
    }

    let task = await store.send(.task)
    continuation.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
    }
    await store.receive(\.syncStatusChanged)
    await store.send(\.binding.selection, .category(.heart)) {
      $0.selection = .category(.heart)
    }
    await store.send(\.binding.searchText, "steps") {
      $0.searchText = "steps"
    }
    continuation.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.selection = .summary
      $0.searchText = ""
    }
    await store.receive(\.signIn.readyToSignIn)
    await task.cancel()
    // Deleting the local data.
    await store.finish()
  }

  @Test(.timeLimit(.minutes(1)))
  func signingOutStopsTheAccountsWorkAndForgetsIt() async {
    let (updates, session) = AsyncStream<Bool>.makeStream()
    // Never advanced: both requests are still waiting when the account signs out.
    let clock = ManualClock()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = {}
      $0.auth.signedInUpdates = { updates }
      $0.sync = .constant(.idle)
      $0.continuousClock = clock
      $0.dataExports.request = { () throws(DataExportError) in
        try? await clock.sleep(for: .seconds(3600))
        return DataExport(requestedAt: Date(timeIntervalSince1970: 0), url: nil)
      }
      $0.signInMethods.list = { () throws(SignInMethodError) in
        try? await clock.sleep(for: .seconds(3600))
        return []
      }
      $0.connectedAgents.list = { () throws(ConnectedAgentsError) in
        try? await clock.sleep(for: .seconds(3600))
        return []
      }
      $0.connectedAgents.accessLog = { _ throws(ConnectedAgentsError) in
        try? await clock.sleep(for: .seconds(3600))
        return RemoteAgentAccessPage(entries: [], nextBefore: nil)
      }
    }

    let task = await store.send(.task)
    session.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
    }
    await store.receive(\.syncStatusChanged)
    // The Settings window loads the sign-in methods and starts an export, which carries on if
    // the window closes.
    await store.send(\.account.signInMethods.task)
    await store.send(\.account.dataExport.exportButtonTapped) {
      $0.account.dataExport.status = .preparing
    }
    // The Agents pane reads the remote agents and their log.
    await store.send(\.connectedAgents.appeared) {
      $0.connectedAgents.isLoadingLog = true
    }
    session.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.account = AccountFeature.State()
      $0.connectedAgents = ConnectedAgentsFeature.State()
    }
    await store.receive(\.signIn.readyToSignIn)
    await task.cancel()
    // Both were cancelled with the account, so nothing is left running.
    await store.finish()
  }

  @Test
  func theAccountPaneForgetsPastResultsWhenItOpens() async {
    var state = AppFeature.State(isSignedIn: true)
    state.account.dataExport.status = .failed("Exporting isn't possible right now.")
    state.account.signInMethods.failure = "Linking didn't work."
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(\.account.appeared) {
      $0.account.dataExport.status = .idle
      $0.account.signInMethods.failure = nil
    }

    // An export in progress carries on.
    var exporting = AppFeature.State(isSignedIn: true)
    exporting.account.dataExport.status = .downloading(0.5)
    let busy = TestStore(initialState: exporting) {
      AppFeature()
    }
    await busy.send(\.account.appeared)
  }

  @Test(.timeLimit(.minutes(1)))
  func syncsWhileSignedInAndDeletesTheLocalDataOnSigningOut() async throws {
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let (statuses, status) = AsyncStream<SyncStatus>.makeStream()
    let events = LockIsolated<[String]>([])
    // A cached blob, which goes with the account.
    let blobs = URL.temporaryDirectory.appending(path: "BlobCache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: blobs.appending(path: "blob"))
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = { events.withValue { $0.append("agent access reset") } }
      $0.auth.signedInUpdates = { updates }
      $0.sync = SyncClient(
        run: {
          events.withValue { $0.append("run") }
          try? await Task.sleep(for: .seconds(3600))
          events.withValue { $0.append("run ended") }
        },
        listen: { _ in
          events.withValue { $0.append("listen") }
          try? await Task.sleep(for: .seconds(3600))
          events.withValue { $0.append("listen ended") }
        },
        syncNow: {},
        push: { _ in },
        status: { statuses },
        removeLocalData: { events.withValue { $0.append("removed") } })
      $0.blobCache = BlobCache(
        directory: blobs, maxBytes: 1 << 20, url: { _ in throw CancellationError() },
        download: .testValue)
    }

    let task = await store.send(.task)
    session.yield(true)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = true
    }
    let syncedAt = Date(timeIntervalSince1970: 1_760_400_000)
    status.yield(.upToDate(at: syncedAt))
    await store.receive(\.syncStatusChanged) {
      $0.syncStatus = .upToDate(at: syncedAt)
    }
    #expect(Set(events.value) == ["run", "listen"])

    // Try Again starts a new pull.
    await store.send(.retrySyncButtonTapped)
    while events.value.filter({ $0 == "run" }).count < 2 { await Task.yield() }
    #expect(events.value.contains("run ended"))
    // Hearing again that it's signed in doesn't start another sync.
    session.yield(true)
    await store.receive(\.signedInChanged)

    session.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.syncStatus = .idle
    }
    await store.receive(\.signIn.readyToSignIn)
    session.finish()
    await task.finish()
    await store.finish()
    // Stopped, and the local data deleted. The engine makes the deletion wait for a pull being
    // cancelled (`LilSyncEngine.removeLocalData()`).
    #expect(events.value.filter { $0 == "run" }.count == 2)
    #expect(events.value.filter { $0 == "run ended" }.count == 2)
    #expect(events.value.contains("listen ended"))
    #expect(events.value.contains("removed"))
    // Access for tools and agents is off again, and their log empty, for the next account.
    #expect(events.value.contains("agent access reset"))
    #expect(!FileManager.default.fileExists(atPath: blobs.path(percentEncoded: false)))
  }

  @Test
  func signOutEndsTheSession() async {
    let signedOut = LockIsolated(false)
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.auth.signOut = { signedOut.setValue(true) }
    }
    await store.send(.signOutButtonTapped)
    await store.finish()
    #expect(signedOut.value)
  }

  @Test
  func searchFindsDataTypesByName() {
    var state = AppFeature.State(isSignedIn: true)
    #expect(state.searchResults.isEmpty)

    state.searchText = "  heart rate  "
    let names = state.searchResults.map(\.name)
    #expect(names.contains("Heart Rate"))
    #expect(names.allSatisfy { $0.localizedStandardContains("heart rate") })
    // In the sidebar's category order.
    let categories = state.searchResults.compactMap(\.category)
    #expect(
      categories
        == categories.sorted {
          HealthCategory.allCases.firstIndex(of: $0)! < HealthCategory.allCases.firstIndex(of: $1)!
        })

    state.searchText = "xylophone"
    #expect(state.searchResults.isEmpty)
    // Spaces alone aren't a search.
    state.searchText = "   "
    #expect(state.query.isEmpty)
  }

  @Test
  func searchCoversEveryVersionButNotCharacteristics() {
    let state = AppFeature.State(isSignedIn: true, searchText: "menopause")
    // Added in iOS 27, and synced from iPhones that have it.
    #expect(!state.searchResults.isEmpty)
    #expect(AppFeature.State(isSignedIn: true, searchText: "blood type").searchResults.isEmpty)
  }

  @Test
  func clearingTheSearchSelectsTheFoundTypesCategory() async {
    let store = TestStore(
      initialState: AppFeature.State(
        isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierHeartRate"),
        searchText: "heart")
    ) {
      AppFeature()
    }
    await store.send(\.binding.searchText, "") {
      $0.searchText = ""
      $0.selection = .category(.heart)
    }
  }
}
