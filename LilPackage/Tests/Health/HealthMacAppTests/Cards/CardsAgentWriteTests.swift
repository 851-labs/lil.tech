import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import HealthCards
import HealthDatabase
import LilSync
import LilTestSupport
import SQLiteData
import Testing

@testable import HealthCardEditor
@testable import HealthMacApp

private let now = Date(timeIntervalSince1970: 1_760_500_000)
private let nowMilliseconds = 1_760_500_000_000

private let seedCards = HealthCards.welcomeSeed.map {
  Card(
    id: $0.id, spec: $0.spec, position: $0.position, createdAt: 1_760_400_000_000,
    updatedAt: 1_760_400_000_000, seed: $0.seed)
}

private func spec(_ name: String) -> CardSpec {
  try! CardSpec(
    input: [
      "version": 1, "display": ["name": .string(name)],
      "series": [["type": "HKQuantityTypeIdentifierHeartRate"]],
    ])
}

/// A generator whose numbers are always the same.
private struct FixedGenerator: RandomNumberGenerator {
  var value: UInt64 = 0
  mutating func next() -> UInt64 {
    value &+= 0x9e37_79b9_7f4a_7c15
    return value
  }
}

/// How the app answered an agent.
private enum Answer: Equatable {
  case ok(HealthAppActionResult)
  case failed(String)
}

/// An agent's request, with what it was answered.
private func agentRequest(_ action: HealthAppAction) -> (
  HealthAppActionRequest, LockIsolated<[Answer]>
) {
  let answers = LockIsolated<[Answer]>([])
  let request = HealthAppActionRequest(action: action) { result in
    answers.withValue {
      switch result {
      case .success(let value): $0.append(.ok(value))
      case .failure(let error): $0.append(.failed(error.localizedDescription))
      }
    }
  }
  return (request, answers)
}

/// The local MCP server's card writes (851-4014), as the app performs them: like the editor's,
/// shown at once and written through sync, and answered once they're stored, or with why not.
@Suite(
  .dependencies {
    $0.date.now = now
    $0.uuid = .incrementing
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(FixedGenerator())
  })
@MainActor
struct CardsAgentWriteTests {
  let database: any DatabaseWriter
  /// What the feature pushed, in order.
  let pushed = LockIsolated<[[SyncMutation]]>([])

  init() throws {
    database = try HealthDatabase.make()
  }

  private func store(
    cards: [Card]? = seedCards, push: (@Sendable ([SyncMutation]) async throws -> Void)? = nil
  ) -> TestStoreOf<CardsFeature> {
    TestStore(initialState: CardsFeature.State(cards: cards)) {
      CardsFeature.mac
    } withDependencies: { [database, pushed] in
      $0.defaultDatabase = database
      $0.sync.push = push ?? { mutations in pushed.withValue { $0.append(mutations) } }
    }
  }

  private func agent(_ id: Int, _ request: HealthAppActionRequest)
    -> CardsFeature.State
    .AgentRequest
  {
    CardsFeature.State.AgentRequest(id: UUID(id), request: request)
  }

  @Test
  func createsACardAndAnswersOnceItsStored() async throws {
    let store = store()
    var generator = FixedGenerator()
    let id = CardID.make(at: now, using: &generator)
    let new = try Card.new(spec("Agent"), after: seedCards, id: id, now: now)
    let (request, answers) = agentRequest(.createCard(spec("Agent")))

    await store.send(.agentRequested(request)) {
      $0.cards.append(new)
      $0.unsaved = [
        .init(
          mutations: [try new.upsert()], upserted: [new], agent: self.agent(0, request),
          answer: .card(id: id))
      ]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(answers.value == [.ok(.card(id: id))])
    #expect(pushed.value == [[try new.upsert()]])
    // Never the editor's alerts.
    #expect(store.state.writeError == nil && store.state.alert == nil)
  }

  @Test
  func replacesASpecItCantReadKeepingItsPlace() async throws {
    var later = seedCards[1]
    later.spec = nil
    later.storedSpec = ["version": 3, "display": ["name": "Later"]]
    let store = store(cards: [seedCards[0], later])
    let replaced = try later.replaced(with: spec("Heart, asleep"), now: now)
    let (request, answers) = agentRequest(.updateCard(id: later.id, spec: spec("Heart, asleep")))

    await store.send(.agentRequested(request)) {
      $0.cards[id: later.id] = replaced
      $0.unsaved = [
        .init(
          mutations: [try replaced.upsert()], upserted: [replaced], agent: self.agent(0, request),
          answer: .card(id: later.id))
      ]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(replaced.position == later.position && replaced.updatedAt == nowMilliseconds)
    #expect(answers.value == [.ok(.card(id: later.id))])
  }

  @Test
  func deletesAndReorders() async throws {
    let store = store()
    let (delete, deleted) = agentRequest(.deleteCard(id: "card_seed_weight"))
    await store.send(.agentRequested(delete)) {
      $0.cards.remove(id: "card_seed_weight")
      $0.unsaved = [
        .init(
          mutations: [seedCards[5].delete], deleted: ["card_seed_weight"],
          agent: self.agent(0, delete))
      ]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(deleted.value == [.ok(.done)])

    // The last first: only it moves.
    let ids = seedCards[0..<5].map(\.id)
    let order = [ids[4]] + ids[0..<4]
    let moved = try Card.reordering(Array(seedCards[0..<5]), to: order, now: now)
    let (reorder, reordered) = agentRequest(.reorderCards(ids: order))
    await store.send(.agentRequested(reorder)) {
      $0.cards = CardsFeature.State.merged(
        Array(seedCards[0..<5]), [.init(mutations: [], upserted: moved)])
      $0.unsaved = [
        .init(
          mutations: try moved.map { try $0.upsert() }, upserted: moved,
          agent: self.agent(1, reorder))
      ]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(store.state.cards.map(\.id) == order)
    #expect(reordered.value == [.ok(.done)])

    // Already in order: answered at once, with nothing written.
    let (again, unchanged) = agentRequest(.reorderCards(ids: order))
    await store.send(.agentRequested(again))
    await store.finish()
    #expect(unchanged.value == [.ok(.done)])
    #expect(pushed.value.count == 2)
  }

  @Test
  func refusalsAreAnsweredInTheRemoteServersWords() async throws {
    let store = store()
    for (action, message): (HealthAppAction, String) in [
      (.deleteCard(id: "card_nope"), #"No card with the id "card_nope". list_cards lists them."#),
      (
        .updateCard(id: "card_nope", spec: spec("Nope")),
        #"No card with the id "card_nope". list_cards lists them."#
      ),
      (
        .reorderCards(ids: ["card_seed_steps"]),
        "reorder_cards needs every card's id once: missing "
          + seedCards.dropFirst().map(\.id).joined(separator: ", ") + ". list_cards lists them."
      ),
    ] {
      let (request, answers) = agentRequest(action)
      await store.send(.agentRequested(request))
      await store.finish()
      #expect(answers.value == [.failed(message)], "\(action)")
    }
    let full = self.store(
      cards: (0..<HealthCards.maxCards).map {
        Card(id: "card_\($0)", spec: spec("\($0)"), position: "a\($0)", createdAt: 1, updatedAt: 1)
      })
    let (create, refused) = agentRequest(.createCard(spec("One more")))
    await full.send(.agentRequested(create))
    await full.finish()
    #expect(
      refused.value == [.failed("You have 100 cards, the most lil health keeps. Delete one first.")]
    )
    #expect(pushed.value.isEmpty)
    #expect(store.state.writeError == nil)
  }

  @Test
  func waitsForTheCardsToBeRead() async throws {
    let store = store(cards: nil)
    let (request, answers) = agentRequest(.deleteCard(id: "card_seed_steps"))
    await store.send(.agentRequested(request)) {
      $0.waitingAgentRequests = [self.agent(0, request)]
    }
    await store.send(.cardsLoaded(seedCards)) {
      $0.cards = IdentifiedArray(uniqueElements: seedCards.dropFirst())
      $0.isLoading = false
      $0.waitingAgentRequests = []
      $0.unsaved = [
        .init(
          mutations: [seedCards[0].delete], deleted: ["card_seed_steps"],
          agent: self.agent(0, request))
      ]
    }
    await store.receive(\.pushFinished) {
      $0.unsaved = []
    }
    #expect(answers.value == [.ok(.done)])

    // Cards that can't be read fail what's waiting.
    let failing = self.store(cards: nil)
    let (waiting, failed) = agentRequest(.deleteCard(id: "card_seed_steps"))
    await failing.send(.agentRequested(waiting)) {
      $0.waitingAgentRequests = [self.agent(1, waiting)]
    }
    await failing.send(.cardsFailedToLoad("The database is locked.")) {
      $0.isLoading = false
      $0.loadFailure = "The database is locked."
      $0.waitingAgentRequests = []
    }
    await failing.finish()
    #expect(failed.value == [.failed("The database is locked.")])
  }

  @Test
  func aWriteThatFailsLocallyIsAnsweredSo() async throws {
    struct Full: Error {}
    let store = store(push: { _ in throw Full() })
    store.exhaustivity = .off
    let (request, answers) = agentRequest(.deleteCard(id: "card_seed_steps"))
    let issues = await issuesReported {
      await store.send(.agentRequested(request))
      await store.receive(\.pushFailed)
    }
    #expect(issues == ["Caught error: Full()"])
    #expect(answers.value == [.failed("lil health couldn't save the card.")])
  }
}
