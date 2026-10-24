import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthAgentAccess
import HealthCatalog
import HealthDatabase
import LilAuth
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthMacApp

private let steps = HealthPage.dataType(
  HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!)!
private let visionPrescriptions = HealthDatabase.visionPrescriptionType
private let visionPrescriptionsPage = HealthPage.dataType(
  HealthCatalog.type(id: visionPrescriptions)!)!

// App actions (851-2892). Synthetic data only, and temporary directories for the access setting.
// Signing in follows the account's cards (851-3204), in a database of their own.
@Suite(.dependencies { $0.defaultDatabase = try! HealthDatabase.make() })
@MainActor
struct HealthAppIntentsTests {
  private let directory = URL.temporaryDirectory.appending(
    path: "AgentAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
  private var accessStore: AgentAccessStore { AgentAccessStore(directory: directory) }

  // MARK: - AppFeature

  @Test
  func opensEachKindOfPageAndClearsTheSearch() async {
    let store = TestStore(
      initialState: AppFeature.State(
        isSignedIn: true, selection: .dataType("HKQuantityTypeIdentifierHeartRate"),
        searchText: "heart")
    ) {
      AppFeature()
    }
    // A type opens in its category, as if its card were clicked.
    await store.send(.pageOpened(steps)) {
      $0.searchText = ""
      $0.selection = .category(.activity)
      $0.metricPath = ["HKQuantityTypeIdentifierStepCount"]
    }
    await store.send(.pageOpened(.category(.heart))) {
      $0.selection = .category(.heart)
      $0.metricPath = []
    }
    // In Body Measurements, as in Health (851-3187).
    await store.send(.pageOpened(visionPrescriptionsPage)) {
      $0.selection = .category(.bodyMeasurements)
      $0.metricPath = [visionPrescriptions]
    }
    await store.send(\.binding.searchText, "sleep") {
      $0.searchText = "sleep"
    }
    await store.send(.pageOpened(.summary)) {
      $0.searchText = ""
      $0.selection = .summary
      $0.metricPath = []
    }
  }

  /// A category's stack is the store's: opening the category shows it with nothing pushed
  /// (851-3030).
  @Test
  func openingACategoryPopsWhatsPushedOnIt() async {
    let store = TestStore(
      initialState: AppFeature.State(
        isSignedIn: true, selection: .category(.bodyMeasurements),
        metricPath: [visionPrescriptions])
    ) {
      AppFeature()
    }
    await store.send(.pageOpened(.category(.bodyMeasurements))) {
      $0.metricPath = []
    }
    // With nothing pushed, it stays as it is.
    await store.send(.pageOpened(.category(.bodyMeasurements)))
    // A type opens on its category's stack.
    await store.send(.pageOpened(visionPrescriptionsPage)) {
      $0.metricPath = [visionPrescriptions]
    }
  }

  /// Through the intents' channel, as Shortcuts and Spotlight open a page (851-3030).
  @Test(.timeLimit(.minutes(1)))
  func anIntentOpeningACategoryPopsWhatsPushedOnIt() async throws {
    let actions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let store = TestStore(
      initialState: AppFeature.State(
        selection: .category(.bodyMeasurements), metricPath: [visionPrescriptions])
    ) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = {}
      $0.auth.signedInUpdates = { updates }
      $0.healthAppActions = actions
      $0.sync = .constant(.idle)
      // For the sync footer's wait, which the first pull never ends.
      $0.continuousClock = ManualClock()
    }
    store.exhaustivity = .off

    let task = await store.send(.task)
    session.yield(true)
    await store.receive(\.signedInChanged)

    let category = Task {
      try await actions.perform(.open(.category(.bodyMeasurements)), { _ in })
    }
    await store.receive(\.appActionRequested)
    await store.receive(\.pageOpened) {
      $0.selection = .category(.bodyMeasurements)
      $0.metricPath = []
    }
    #expect(try await category.value == .done)

    session.yield(false)
    await store.receive(\.signedInChanged)
    await task.cancel()
    await store.finish()
  }

  @Test
  func choosingAnotherPageEmptiesTheMetricPath() async {
    let store = TestStore(
      initialState: AppFeature.State(
        isSignedIn: true, selection: .category(.activity),
        metricPath: ["HKQuantityTypeIdentifierStepCount"])
    ) {
      AppFeature()
    }
    await store.send(\.binding.selection, .category(.heart)) {
      $0.selection = .category(.heart)
      $0.metricPath = []
    }
  }

  @Test
  func aStackGoingAwayCantEmptyTheNextOnesPath() async {
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    }
    await store.send(.pageOpened(steps)) {
      $0.selection = .category(.activity)
      $0.metricPath = ["HKQuantityTypeIdentifierStepCount"]
    }
    // Summary's stack, on its way out.
    await store.send(.metricPathChanged([], selection: .summary))
    // Activity's own Back.
    await store.send(.metricPathChanged([], selection: .category(.activity))) {
      $0.metricPath = []
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func servesActionsWhileSignedInAndFailsThemOnceSignedOut() async throws {
    let actions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = {}
      $0.auth.signedInUpdates = { updates }
      $0.healthAppActions = actions
      $0.sync = .constant(.idle)
      // For the sync footer's wait, which the first pull never ends.
      $0.continuousClock = ManualClock()
    }
    store.exhaustivity = .off

    let task = await store.send(.task)
    session.yield(true)
    await store.receive(\.signedInChanged)

    let opened = Task { try await actions.perform(.open(steps), { _ in }) }
    await store.receive(\.appActionRequested)
    await store.receive(\.pageOpened) {
      $0.selection = .category(.activity)
      $0.metricPath = ["HKQuantityTypeIdentifierStepCount"]
    }
    #expect(try await opened.value == .done)

    // Signed out, the app serves nothing more.
    session.yield(false)
    await store.receive(\.signedInChanged)
    await #expect(throws: HealthAppActionError.signedOut) {
      try await actions.perform(.open(.summary), { _ in })
    }
    await task.cancel()
    await store.finish()
  }

  // MARK: - The channel

  @Test(.timeLimit(.minutes(1)))
  func anActionWaitsForSignInAfterLaunch() async throws {
    let channel = HealthAppActionChannel(signInWait: .seconds(30), pollInterval: .milliseconds(10))
    let opened = Task { try await channel.perform(.open(.summary)) }
    // The store starts serving after the action asked.
    try await Task.sleep(for: .milliseconds(50))
    for await request in channel.requests() {
      #expect(request.action == .open(.summary))
      request.finish(.success(.done))
      break
    }
    #expect(try await opened.value == .done)
  }

  @Test(.timeLimit(.minutes(1)))
  func signingOutFailsWhatTheAppHadntAnswered() async throws {
    let channel = HealthAppActionChannel(signInWait: .zero)
    let requests = channel.requests()
    let (received, receivedOne) = AsyncStream<Void>.makeStream()
    // Reads requests and never answers them.
    let serving = Task {
      for await _ in requests { receivedOne.yield() }
    }
    let opened = Task { try await channel.perform(.open(.summary)) }
    for await _ in received { break }
    serving.cancel()
    await #expect(throws: HealthAppActionError.signedOut) { try await opened.value }
  }

  @Test(.timeLimit(.minutes(1)))
  func aReplacedServerStillAnswersWhatItRead() async throws {
    let channel = HealthAppActionChannel(signInWait: .zero)
    let first = channel.requests()
    let opened = Task { try await channel.perform(.open(.summary)) }
    // Another server starts before the first has read the request.
    while channel.pendingCount == 0 { await Task.yield() }
    _ = channel.requests()
    for await request in first {
      request.finish(.success(.done))
      break
    }
    #expect(try await opened.value == .done)
  }

  @Test
  func failsAtOnceWhenNotSignedInAfterTheWait() async {
    let channel = HealthAppActionChannel(signInWait: .zero)
    await #expect(throws: HealthAppActionError.signedOut) {
      try await channel.perform(.open(.summary))
    }
  }

  // MARK: - The intent's perform

  @Test
  func refusesAndLogsNothingWhileAccessIsOff() async throws {
    let asked = LockIsolated<[HealthAppAction]>([])
    let broughtForward = LockIsolated(false)
    await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions.perform = { action, _ in
        asked.withValue { $0.append(action) }
        return .done
      }
    } operation: {
      let error = await #expect(throws: HealthAppIntentError.self) {
        try await HealthAppIntents.perform(.open(steps)) { broughtForward.setValue(true) }
      }
      #expect(error?.message == AgentAccessError.off.localizedDescription)
      #expect(error?.message.contains("Allow access on this Mac") == true)
    }
    #expect(asked.value.isEmpty)
    #expect(!broughtForward.value)
    #expect(try accessStore.entries().isEmpty)
  }

  @Test
  func logsTheActionThenAsksTheAppWhileAccessIsOn() async throws {
    try accessStore.setEnabled(true)
    let asked = LockIsolated<[HealthAppAction]>([])
    let broughtForward = LockIsolated(false)
    let result = try await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions.perform = { action, _ in
        // Forward first, then the page.
        #expect(broughtForward.value)
        asked.withValue { $0.append(action) }
        return .done
      }
    } operation: {
      try await HealthAppIntents.perform(.open(steps)) { broughtForward.setValue(true) }
    }
    #expect(result == .done)
    #expect(asked.value == [.open(steps)])
    let entries = try accessStore.entries()
    #expect(entries.map(\.command) == ["open Steps"])
    #expect(entries.map(\.process) == ["Shortcuts, Siri or Spotlight"])
  }

  @Test
  func failsWithSignInFirstWhenSignedOut() async throws {
    try accessStore.setEnabled(true)
    await withDependencies {
      $0.agentAccess = .live(accessStore)
      $0.healthAppActions = HealthAppActions(channel: HealthAppActionChannel(signInWait: .zero))
    } operation: {
      await #expect(throws: HealthAppActionError.signedOut) {
        try await HealthAppIntents.perform(.open(.summary))
      }
      #expect(HealthAppActionError.signedOut.localizedDescription == "Sign in to lil health first.")
    }
    // Asked while access was on, so it's in the log.
    #expect(try accessStore.entries().map(\.command) == ["open Summary"])
  }

  // MARK: - Finding pages

  @Test
  func findsTypesByNameAndByIdentifier() async throws {
    let query = HealthPageQuery()
    #expect(try await query.entities(matching: "Steps").first == steps)
    #expect(try await query.entities(matching: "steps").first == steps)
    #expect(try await query.entities(matching: "StepCount").first == steps)
    #expect(
      try await query.entities(matching: "HKQuantityTypeIdentifierStepCount").first == steps)
    // As the sidebar's search: any part of a name.
    let heart = try await query.entities(matching: "heart")
    #expect(heart.first == .category(.heart))
    #expect(heart.contains { $0.name == "Heart Rate" })
    #expect(heart.allSatisfy { $0.name.localizedStandardContains("heart") })
    // Exact names first: the category, then the type of the same name.
    let sleep = try await query.entities(matching: "Sleep")
    #expect(sleep.first == .category(.sleep))
    // Health Details and its characteristics are no pages (851-3187).
    #expect(try await query.entities(matching: "Health Details").isEmpty)
    #expect(try await query.entities(matching: "blood type").isEmpty)
    #expect(try await query.entities(matching: "BloodType").isEmpty)
    #expect(try await query.entities(matching: "Activity Move Mode").isEmpty)
    #expect(try await query.entities(matching: "xylophone").isEmpty)
  }

  @Test
  func suggestsSummaryAndTheCategories() async throws {
    let suggested = try await HealthPageQuery().suggestedEntities()
    #expect(suggested == [.summary] + HealthCategory.allCases.map(HealthPage.category))
  }

  @Test
  func pagesRoundTripThroughTheirIDs() async throws {
    #expect(HealthPage.summary.id == "summary")
    #expect(HealthPage.category(.mentalWellbeing).id == "category:mentalWellbeing")
    #expect(steps.id == "type:HKQuantityTypeIdentifierStepCount")
    let all = HealthPage.all
    #expect(try await HealthPageQuery().entities(for: all.map(\.id)) == all)
    // Health Details' ID, from a Shortcut made before it went (851-3187), and its
    // characteristics'.
    #expect(HealthPage(id: "health-details") == nil)
    #expect(HealthPage(id: "type:HKCharacteristicTypeIdentifierBloodType") == nil)
    #expect(HealthPage(id: "type:HKCharacteristicTypeIdentifierActivityMoveMode") == nil)
    #expect(HealthPage(id: "category:nope") == nil)
    #expect(HealthPage(id: "Steps") == nil)
  }

  /// A type's subtitle is the category it opens in.
  @Test
  func typesAreSubtitledWithWhereTheyOpen() {
    #expect(steps.subtitle == "Activity")
    #expect(visionPrescriptionsPage.subtitle == "Body Measurements")
    #expect(HealthPage.category(.heart).subtitle == nil)
    for page in HealthPage.all {
      guard case .dataType = page.kind else { continue }
      #expect(page.subtitle != nil, "\(page.name)")
    }
  }

  @Test
  func theLogNamesThePage() {
    #expect(HealthAppAction.open(steps).command == "open Steps")
    #expect(HealthAppAction.open(.category(.heart)).command == "open Heart")
  }
}
