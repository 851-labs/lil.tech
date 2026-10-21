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

// Fresh app storage for each test: pins live there.
@Suite(.dependencies)
@MainActor
struct SummaryFeatureTests {
  private let steps = "HKQuantityTypeIdentifierStepCount"
  private let heartRate = "HKQuantityTypeIdentifierHeartRate"
  private let weight = "HKQuantityTypeIdentifierBodyMass"

  @Test
  func pinsUnpinsAndReordersThroughSync() async throws {
    let pushed = LockIsolated<[[SyncMutation]]>([])
    let clock = ManualClock()
    let store = TestStore(initialState: SummaryFeature.State(pins: [])) {
      SummaryFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.defaultDatabase = try! HealthDatabase.make()
      $0.sync.push = { mutations in pushed.withValue { $0.append(mutations) } }
    }
    await store.send(.editButtonTapped) { $0.isEditing = true }
    await store.send(.pinButtonTapped(steps)) { $0.pins = [self.steps] }
    await store.send(.pinButtonTapped(heartRate)) { $0.pins = [self.steps, self.heartRate] }
    // Pinning twice doesn't duplicate it, or write anything.
    await store.send(.pinButtonTapped(steps))
    await store.send(.pinButtonTapped(weight)) {
      $0.pins = [self.steps, self.heartRate, self.weight]
    }
    await store.send(.pinsMoved([2], 0)) { $0.pins = [self.weight, self.steps, self.heartRate] }
    await store.send(.unpinButtonTapped(steps)) { $0.pins = [self.weight, self.heartRate] }
    await store.send(\.binding.search, "heart") { $0.search = "heart" }
    await store.send(.doneButtonTapped) {
      $0.isEditing = false
      $0.search = ""
    }
    // The burst is one write, of how the pins ended up.
    try await clock.waitUntilAsleep(dueWithin: SummaryFeature.writeDelay)
    clock.advance(by: SummaryFeature.writeDelay)
    await store.finish()
    #expect(pushed.value == [HealthDatabase.pinMutations(from: [], to: [weight, heartRate])])
  }

  @Test
  func readsThePinsFromTheSyncedTable() async throws {
    let database = try HealthDatabase.make()
    try await database.write { db in
      try HealthPin.insert {
        HealthPin(id: self.heartRate, position: 1)
        HealthPin(id: self.steps, position: 0)
      }
      .execute(db)
    }
    let store = TestStore(initialState: SummaryFeature.State()) {
      SummaryFeature()
    } withDependencies: {
      $0.defaultDatabase = database
    }
    #expect(store.state.isLoadingPins)
    let task = await store.send(.task)
    await store.receive(\.pinsLoaded) {
      $0.pins = [self.steps, self.heartRate]
      $0.isLoadingPins = false
    }
    // Another Mac's change arrives with sync.
    try await database.write { db in
      try HealthPin.find(self.steps).delete().execute(db)
    }
    await store.receive(\.pinsLoaded) { $0.pins = [self.heartRate] }
    await task.cancel()
  }

  @Test
  func closingTheEditorAnyWayClearsItsSearch() async {
    let store = TestStore(initialState: SummaryFeature.State(isEditing: true)) {
      SummaryFeature()
    }
    await store.send(\.binding.search, "sleep") { $0.search = "sleep" }
    // Esc, through the sheet's binding.
    await store.send(\.binding.isEditing, false) {
      $0.isEditing = false
      $0.search = ""
    }
  }

  @Test
  func duplicatedPinsShowOnceAndMoveAsShown() async throws {
    let state = SummaryFeature.State(pins: [steps, heartRate, steps, weight])
    #expect(state.orderedPins == [steps, heartRate, weight])
    let clock = ManualClock()
    let store = TestStore(initialState: state) {
      SummaryFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.defaultDatabase = try! HealthDatabase.make()
      $0.sync.push = { _ in }
    }
    await store.send(.pinsMoved([2], 0)) { $0.pins = [self.weight, self.steps, self.heartRate] }
    try await clock.waitUntilAsleep(dueWithin: SummaryFeature.writeDelay)
    clock.advance(by: SummaryFeature.writeDelay)
    await store.finish()
  }

  @Test
  func theEditorOffersWhatIsntPinnedMatchingTheSearch() {
    var state = SummaryFeature.State(pins: [heartRate])
    state.search = "heart rate"
    let names = state.unpinned.map(\.name)
    #expect(names.contains("Resting Heart Rate"))
    #expect(!names.contains("Heart Rate"))
    #expect(names.allSatisfy { $0.localizedStandardContains("heart rate") })
  }

  @Test
  func signingOutClearsThePins() async {
    let (updates, session) = AsyncStream<Bool>.makeStream()
    let store = TestStore(initialState: AppFeature.State(isSignedIn: true)) {
      AppFeature()
    } withDependencies: {
      $0.agentAccess.reset = {}
      $0.auth.signedInUpdates = { updates }
      $0.sync = .constant(.idle)
      // The pin's write waits, and signing out cancels it.
      $0.continuousClock = ManualClock()
      $0.defaultDatabase = try! HealthDatabase.make()
    }
    await store.send(.summary(.pinButtonTapped(steps))) { $0.summary.pins = [self.steps] }
    let task = await store.send(.task)
    session.yield(false)
    await store.receive(\.signedInChanged) {
      $0.isSignedIn = false
      $0.summary = SummaryFeature.State()
    }
    await store.receive(\.signIn.readyToSignIn)
    session.finish()
    await task.finish()
    await store.finish()
  }
}

struct HighlightTextTests {
  private let steps = HealthCatalog.type(id: "HKQuantityTypeIdentifierStepCount")!
  private let resting = HealthCatalog.type(id: "HKQuantityTypeIdentifierRestingHeartRate")!

  @Test
  func weeksSayWhichWayTheyWent() {
    let up = Highlight(
      typeID: steps.id, kind: .week, current: 8_000, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(up, type: steps).contains("a day"))
    #expect(HighlightText.sentence(up, type: steps).contains("up from"))
    let same = Highlight(
      typeID: steps.id, kind: .week, current: 7_100, previous: 7_000, recentStart: .now)
    #expect(HighlightText.sentence(same, type: steps).contains("about the same"))
  }

  @Test
  func fromNothingIsAChange() {
    let exercise = HealthCatalog.type(id: "HKQuantityTypeIdentifierAppleExerciseTime")!
    let fromZero = Highlight(
      typeID: exercise.id, kind: .week, current: 30, previous: 0, recentStart: .now)
    #expect(fromZero.direction == .up)
    #expect(HighlightText.sentence(fromZero, type: exercise).contains("up from 0 min"))
  }

  @Test
  func eachValueKeepsItsOwnUnit() {
    let distance = HealthCatalog.type(id: "HKQuantityTypeIdentifierDistanceWalkingRunning")!
    let highlight = Highlight(
      typeID: distance.id, kind: .week, current: 5_200, previous: 950, recentStart: .now)
    let sentence = HighlightText.sentence(highlight, type: distance)
    #expect(sentence.contains("km a day"))
    #expect(sentence.contains("950 m"))
  }

  @Test
  func trendsFollowTheValues() {
    let down = Highlight(
      typeID: resting.id, kind: .trend, current: 58, previous: 66, recentStart: .now)
    #expect(down.direction == .down)
    #expect(HighlightText.sentence(down, type: resting).contains("trending down"))
    // A discrete type's average isn't per day.
    #expect(!HighlightText.sentence(down, type: resting).contains("a day"))
  }
}
