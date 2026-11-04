import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthCardStore
import HealthKit
import HealthKitAccess
import HealthUI
import HealthUpload
import LilAuth
import LilSync
import Testing

@testable import HealthPhoneApp

/// What Summary's rows do as signing in, the cards' first pull and Health access happen, in each
/// order they can (851-4035). A fresh install's Summary can show before Health access is checked,
/// and its HealthKit can take minutes to answer, then answer that it wasn't asked: the rows wait
/// for the check, say when Health access is needed, and run again once it's given. Synthetic data
/// only.
@MainActor
@Suite(.dependencies { $0.sync = .constant(.idle) })
struct SummaryHealthAccessTests {
  private let day = Date(timeIntervalSince1970: 1_760_400_000)
  private let steps = Card.welcomeSeed[0]

  /// What a row does in `state`, as `AppView` and `SummaryView` read it: `nil` while Summary isn't
  /// the screen shown (consent or Health access is; an alert shows over it), or its cards are the
  /// seed's loading rows; otherwise the row's run, which runs its card when it's ready.
  private func run(in state: AppFeature.State) -> CardHeadlines.Run? {
    guard state.isSignedIn == true, state.healthConsent == nil, state.healthAccess == nil,
      case .loaded(let cards) = SummaryLoad(state.cards), let card = cards.first
    else { return nil }
    return CardHeadlines.Run(
      spec: card.spec, day: day, generation: 0,
      needsHealthAccess: state.syncStatus.needsHealthAccess)
  }

  /// Health's answer to whether it has types to ask about, held until `answer`.
  private final class HeldAnswers: Sendable {
    let stream: AsyncStream<Bool>
    let continuation: AsyncStream<Bool>.Continuation
    init() { (stream, continuation) = AsyncStream<Bool>.makeStream() }
    func next() async throws -> Bool {
      for await answer in stream { return answer }
      throw CancellationError()
    }
    func answer(_ needsRequest: Bool) { continuation.yield(needsRequest) }
  }

  private func store(needsRequest: HeldAnswers) -> TestStoreOf<AppFeature> {
    @Shared(.healthConsentPolicyVersion) var version
    // Given before, e.g. on another iPhone: no consent screen.
    $version.withLock { $0 = HealthConsentClient.policyVersion }
    let store = TestStore(initialState: AppFeature.State(isSignedIn: false)) {
      AppFeature()
    } withDependencies: {
      $0.healthCharacteristicsReader = HealthCharacteristicsReader { [] }
      $0.healthActivitySummaryReader = HealthActivitySummaryReader { _ in [] }
      $0.date.now = day
      $0.healthAuthorization.isAvailable = { true }
      $0.healthObserver = HealthObserver { _, _ in }
      $0.accountDevices = AccountDevices { 0 }
      $0.healthAuthorization.needsRequest = { try await needsRequest.next() }
      $0.healthConsent.isGiven = { true }
      $0.backgroundUpload.start = {}
    }
    // Only what Summary's rows read: onboarding has its own tests.
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
  }

  private let pulled = CardsFeature.Action.cardsLoaded(
    SyncedCards(cards: Card.welcomeSeed, isSynced: true))

  /// Pulled, then Summary shows while Health is still being asked whether it has types to ask
  /// about: the rows wait. Health access comes next, then Summary again, whose rows wait for the
  /// next answer, then run.
  @Test
  func pulledBeforeHealthAnswersThenAccessGiven() async throws {
    let needsRequest = HeldAnswers()
    let store = store(needsRequest: needsRequest)
    await store.send(.signedInChanged(true))
    await store.receive(\.consentChecked)
    await store.send(.cards(pulled))
    let waiting = try #require(run(in: store.state))
    #expect(!waiting.isReady)

    needsRequest.answer(true)
    await store.receive(\.healthAccessChecked)
    // Health access takes over.
    #expect(store.state.healthAccess != nil)
    #expect(run(in: store.state) == nil)

    await store.send(.healthAccess(.delegate(.finished)))
    await store.receive(\.startUpload)
    // Summary again: Health is asked again, and hasn't answered yet.
    let asked = try #require(run(in: store.state))
    #expect(!asked.isReady)
    needsRequest.answer(false)
    await store.receive(\.syncStatus.healthAccessChecked)
    let granted = try #require(run(in: store.state))
    #expect(granted.isReady)
    #expect(granted != waiting)
  }

  /// Health access before the first pull: the seed's loading rows, which run nothing, until the
  /// cards arrive, then rows that run at once.
  @Test
  func accessGivenBeforeTheFirstPull() async throws {
    let needsRequest = HeldAnswers()
    let store = store(needsRequest: needsRequest)
    // Onboarding got to the end before, on this iPhone.
    @Shared(.appStorage("offeredPerObjectHealthTypes")) var offered = false
    $offered.withLock { $0 = true }
    await store.send(.signedInChanged(true))
    await store.receive(\.consentChecked)
    needsRequest.answer(false)
    await store.receive(\.healthAccessChecked)
    #expect(store.state.healthAccess == nil)
    #expect(SummaryLoad(store.state.cards) == .loading)
    #expect(run(in: store.state) == nil)

    await store.send(.cards(pulled))
    #expect(try #require(run(in: store.state)).isReady)
  }

  /// Not Now: Summary's rows run, and those whose types Health wasn't asked about say so, rather
  /// than "–" or HealthKit's "Authorization not determined".
  @Test
  func notNowShowsThatAccessIsNeeded() async throws {
    let needsRequest = HeldAnswers()
    let store = store(needsRequest: needsRequest)
    await store.send(.signedInChanged(true))
    await store.receive(\.consentChecked)
    needsRequest.answer(true)
    await store.receive(\.healthAccessChecked)
    await store.send(.healthAccess(.delegate(.skipped)))
    await store.send(.cards(pulled))
    #expect(try #require(run(in: store.state)).isReady == false)
    needsRequest.answer(true)
    await store.receive(\.syncStatus.healthAccessChecked)
    #expect(try #require(run(in: store.state)).isReady)

    let error = HealthAccessNeeded.converting(HKError(.errorAuthorizationNotDetermined))
    #expect(CardRow.Headline(failure: error) == .needsHealthAccess)
  }

  /// Signed in again with the cards still loading: the seed's rows, which run nothing.
  @Test
  func cardsNotPulledYetRunNothing() async {
    let store = store(needsRequest: HeldAnswers())
    await store.send(.signedInChanged(true))
    await store.send(.syncStatus(.healthAccessChecked(needsRequest: false)))
    #expect(SummaryLoad(store.state.cards) == .loading)
    #expect(run(in: store.state) == nil)
  }

  @Test
  func onlyHealthKitNotBeingAskedNeedsAccess() {
    #expect(
      HealthAccessNeeded.converting(HKError(.errorAuthorizationNotDetermined))
        is HealthAccessNeeded)
    let unavailable = HealthAccessNeeded.converting(HKError(.errorHealthDataUnavailable))
    #expect(!(unavailable is HealthAccessNeeded))
    #expect(
      CardRow.Headline(failure: unavailable) == .failed(unavailable.localizedDescription))
    #expect(
      HealthAccessNeeded().localizedDescription
        == "lil health needs access to your Health data to show this card.")
  }

  /// A row's run: ready once the day and Health access are known, and another when either
  /// changes, so a headline kept from before Health access was given isn't shown after.
  @Test
  func rowsWaitForTheDayAndHealthAccess() {
    func run(day: Date?, _ needsHealthAccess: Bool?) -> CardHeadlines.Run {
      CardHeadlines.Run(
        spec: steps.spec, day: day, generation: 0, needsHealthAccess: needsHealthAccess)
    }
    #expect(!run(day: nil, false).isReady)
    #expect(!run(day: day, nil).isReady)
    #expect(run(day: day, true).isReady)
    #expect(run(day: day, false).isReady)
    #expect(run(day: day, true) != run(day: day, false))
  }
}
