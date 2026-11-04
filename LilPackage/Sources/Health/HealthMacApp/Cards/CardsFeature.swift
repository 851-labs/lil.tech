public import ComposableArchitecture
public import Foundation
public import HealthCardEditor
public import HealthCards
public import HealthDatabase
import LilSync
import SQLiteData

/// The account's cards (851-3204, docs/decisions/cards.md): read from the synced `healthCards`
/// table in Summary's order, and created, edited, deleted and moved through sync. Each write is
/// the whole row of the card it changes, written locally and queued for the server
/// (`SyncClient.push`), so it works offline; other devices' and agents' changes arrive as sync
/// pulls them. `AppFeature` follows the cards while signed in; Summary (851-3206), the full-page
/// card and the editor read and write them here.
///
/// A write shows at once. Writes go to sync one at a time, in the order they were made, since the
/// server keeps the last to arrive, and each shows over what's read until it's in the local table
/// (``State/unsaved``): a push waits for a pull or bootstrap in progress, which may change cards
/// meanwhile.
///
/// Writes are validated as apps write them (`CardSpec(input:)`, at most 8 KB), and a 101st card is
/// refused (`HealthCards.maxCards`). A write that's refused sets ``State/writeError``. Writes wait
/// for the cards to be read: before then, there's no end to add a card at. Apps never seed cards:
/// the server does, once per account.
///
/// It presents the card editor (851-3208): New Card…, Edit… and Delete…, from Summary and a
/// card's page, write through it. And Reorder Cards… (851-3210), a list to drag the cards into
/// order, since Summary's grouped form can't reorder its rows by dragging.
///
/// It also performs the local MCP server's card writes (851-4014, ``Action/agentRequested(_:)``):
/// each is a write like the editor's, shown at once, and answered once sync has stored it locally,
/// so the tool reads it back from the database. A refused one is answered with why, in the remote
/// server's words, and never shows in the app's alerts.
@Reducer
public struct CardsFeature {
  @ObservableState
  public struct State: Equatable {
    /// In Summary's order: as last read, with the writes not yet stored over them.
    public var cards: IdentifiedArrayOf<Card>
    /// Whether the cards haven't been read yet, so an empty list would be wrong.
    public var isLoading: Bool
    /// Why the cards couldn't be read.
    public var loadFailure: String?
    /// Why the last write was refused, until ``Action/writeErrorDismissed``.
    public var writeError: CardWriteError?
    /// Writes not yet in the local table, oldest first. The first is being pushed.
    var unsaved: [Write] = []
    /// The card editor, for a new card or one of these.
    @Presents public var editor: CardEditorFeature.State?
    /// Delete…'s confirmation, from a Summary row.
    @Presents public var alert: AlertState<Action.Alert>?
    /// Whether Reorder Cards… is open (851-3210).
    public var isReordering = false
    /// Agents' card writes that came before the cards were read, done once they are.
    var waitingAgentRequests: [AgentRequest] = []

    /// Cards given, e.g. in catalogs, are shown at once; otherwise they're read (``Action/task``).
    public init(cards: [Card]? = nil) {
      self.cards = IdentifiedArray(uniqueElements: cards ?? [])
      self.isLoading = cards == nil
    }

    /// Whether the cards were read, so they can be written.
    public var isLoaded: Bool { !isLoading && loadFailure == nil }

    /// Whether a card can be added: the cards are read, and there are fewer than
    /// `HealthCards.maxCards`.
    public var canCreateCard: Bool {
      isLoaded && cards.count < HealthCards.maxCards
    }

    /// Whether there's an order to change: the cards are read, and there are two or more.
    public var canReorderCards: Bool {
      isLoaded && cards.count > 1
    }

    /// One write: the mutations for sync, and the cards they upsert or delete.
    struct Write: Equatable {
      var mutations: [SyncMutation]
      var upserted: [Card] = []
      var deleted: [Card.ID] = []
      /// The agent's request it does, answered with `answer` once it's stored.
      var agent: AgentRequest?
      var answer: HealthAppActionResult = .done
    }

    /// An agent's card write (``HealthAppActionRequest``), told apart by its ID: who to answer
    /// isn't state the cards show.
    struct AgentRequest: Equatable, Identifiable {
      let id: UUID
      let request: HealthAppActionRequest

      static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// `cards` with `writes` over them, in order.
    static func merged(_ cards: [Card], _ writes: [Write]) -> IdentifiedArrayOf<Card> {
      var merged = IdentifiedArray(cards, uniquingIDsWith: { first, _ in first })
      for write in writes {
        for id in write.deleted { merged.remove(id: id) }
        for card in write.upserted { merged[id: card.id] = card }
      }
      merged.sort { $0.precedes($1) }
      return merged
    }
  }

  public enum Action {
    /// Reads the cards, then follows their changes, until cancelled.
    case task
    /// An agent's card write, from the local MCP server (851-4014): `createCard`, `updateCard`,
    /// `deleteCard` or `reorderCards`. Answered once it's stored, or with why it was refused.
    case agentRequested(HealthAppActionRequest)
    case cardsLoaded([Card])
    case cardsFailedToLoad(String)
    /// Adds a card with `spec` at the end.
    case createCard(CardSpec)
    /// Replaces a card's spec, keeping its place.
    case updateCard(id: Card.ID, spec: CardSpec)
    case deleteCard(id: Card.ID)
    /// Moves the cards at the offsets to before `toOffset`, as `onMove` gives them.
    case moveCards(fromOffsets: IndexSet, toOffset: Int)
    /// Moves the cards to before `before`, or to the end: a drop in Reorder Cards…, by the cards
    /// it showed, so a sync that lands meanwhile can't make it move others.
    case moveCardsBefore(ids: [Card.ID], before: Card.ID?)
    case moveCardUp(id: Card.ID)
    case moveCardDown(id: Card.ID)
    case writeErrorDismissed
    /// New Card…: the editor, for a new card.
    case newCardButtonTapped
    /// Edit…: the editor, for the card.
    case editCardButtonTapped(id: Card.ID)
    /// Delete…: asks first.
    case deleteCardButtonTapped(id: Card.ID)
    /// Reorder Cards…: the cards in a list, to drag into order.
    case reorderCardsButtonTapped
    /// Done, or the sheet closed.
    case reorderingFinished
    case editor(PresentationAction<CardEditorFeature.Action>)
    case alert(PresentationAction<Alert>)
    /// The first unsaved write is in the local table and sync's queue.
    case pushFinished
    /// The first unsaved write failed locally: the cards as stored, read again.
    case pushFailed([Card]?)

    @CasePathable
    public enum Alert: Equatable, Sendable {
      case confirmDelete(id: Card.ID)
    }
  }

  enum CancelID {
    case observation
    /// The write on its way to sync's queue. Signing out cancels it (``cancel()``), so none lands
    /// after the account's data is deleted.
    case write
  }

  /// Stops reading and writing the account's cards, when it signs out.
  public static func cancel<Other>() -> Effect<Other> {
    .merge(.cancel(id: CancelID.observation), .cancel(id: CancelID.write))
  }

  @Dependency(\.date.now) var now
  @Dependency(\.defaultDatabase) var database
  @Dependency(\.sync) var sync
  @Dependency(\.uuid) var uuid
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { [database] send in
          for try await cards in HealthDatabase.cardUpdates(in: database) {
            await send(.cardsLoaded(cards))
          }
        } catch: { error, send in
          guard !(error is CancellationError) else { return }
          await send(.cardsFailedToLoad(error.localizedDescription))
        }
        .cancellable(id: CancelID.observation, cancelInFlight: true)

      case .agentRequested(let request):
        let agent = State.AgentRequest(id: uuid(), request: request)
        if let failure = state.loadFailure {
          return Self.answer(agent, .failure(HealthAppActionError.cardNotSaved(failure)))
        }
        guard state.isLoaded else {
          state.waitingAgentRequests.append(agent)
          return .none
        }
        return perform(agent, &state)

      case .cardsLoaded(let cards):
        state.cards = State.merged(cards, state.unsaved)
        state.isLoading = false
        state.loadFailure = nil
        let waiting = state.waitingAgentRequests
        state.waitingAgentRequests = []
        var effects: [Effect<Action>] = []
        for agent in waiting { effects.append(perform(agent, &state)) }
        return .merge(effects)

      case .cardsFailedToLoad(let message):
        state.isLoading = false
        state.loadFailure = message
        // Nothing to reorder any more: Summary says why.
        state.isReordering = false
        let waiting = state.waitingAgentRequests
        state.waitingAgentRequests = []
        return .merge(
          waiting.map { Self.answer($0, .failure(HealthAppActionError.cardNotSaved(message))) })

      case .createCard(let spec):
        return create(spec, &state)

      case .updateCard(let id, let spec):
        return update(id, spec, &state)

      case .deleteCard(let id):
        guard state.isLoaded, let card = state.cards[id: id] else { return .none }
        state.writeError = nil
        return enqueue(State.Write(mutations: [card.delete], deleted: [id]), &state)

      case .moveCards(let source, let destination):
        guard state.isLoaded else { return .none }
        let cards = Array(state.cards)
        let effect = write(&state) { () throws(CardWriteError) in
          try Card.moving(cards, fromOffsets: source, toOffset: destination, now: now)
        }
        // A move that's refused says so: nothing else would show it (851-3210).
        if let error = state.writeError {
          state.writeError = nil
          state.alert = .cardNotMoved(error)
        }
        return effect

      case .moveCardsBefore(let ids, let before):
        let source = IndexSet(ids.compactMap { state.cards.index(id: $0) })
        guard source.count == ids.count, !ids.isEmpty else { return .none }
        let destination = before.map { state.cards.index(id: $0) } ?? state.cards.count
        guard let destination else { return .none }
        return .send(.moveCards(fromOffsets: source, toOffset: destination))

      case .moveCardUp(let id):
        guard let index = state.cards.index(id: id), index > 0 else { return .none }
        return .send(.moveCards(fromOffsets: [index], toOffset: index - 1))

      case .moveCardDown(let id):
        guard let index = state.cards.index(id: id), index < state.cards.count - 1 else {
          return .none
        }
        return .send(.moveCards(fromOffsets: [index], toOffset: index + 2))

      case .writeErrorDismissed:
        state.writeError = nil
        return .none

      case .pushFinished:
        guard !state.unsaved.isEmpty else { return .none }
        let write = state.unsaved.removeFirst()
        return .merge(
          write.agent.map { Self.answer($0, .success(write.answer)) } ?? .none, pushNext(state))

      case .pushFailed(let stored):
        guard !state.unsaved.isEmpty else { return .none }
        let write = state.unsaved.removeFirst()
        if let stored { state.cards = State.merged(stored, state.unsaved) }
        return .merge(
          write.agent.map {
            Self.answer(
              $0, .failure(HealthAppActionError.cardNotSaved("lil health couldn't save the card.")))
          } ?? .none,
          pushNext(state))

      case .newCardButtonTapped:
        guard state.canCreateCard else { return .none }
        state.editor = CardEditorFeature.State()
        return .none

      case .editCardButtonTapped(let id):
        guard let card = state.cards[id: id] else { return .none }
        state.editor = CardEditorFeature.State(editing: card)
        return .none

      case .deleteCardButtonTapped(let id):
        guard let card = state.cards[id: id] else { return .none }
        state.alert = .confirmDeleteCard(named: card.storedName, .confirmDelete(id: card.id))
        return .none

      case .reorderCardsButtonTapped:
        guard state.canReorderCards else { return .none }
        state.isReordering = true
        return .none

      case .reorderingFinished:
        state.isReordering = false
        return .none

      case .alert(.presented(.confirmDelete(let id))):
        return .send(.deleteCard(id: id))

      case .editor(.presented(.delegate(.save(let spec)))):
        guard let editor = state.editor else { return .none }
        guard state.isLoaded else {
          state.editor?.saveError = "Your cards haven't loaded yet. Try again in a moment."
          return .none
        }
        let writes = state.unsaved.count
        let effect: Effect<Action>
        if let id = editor.cardID {
          effect = update(id, editor.written(spec, over: state.cards[id: id]?.spec), &state)
        } else {
          effect = create(spec, &state)
        }
        // A write that's refused, or that failed some other way (reported), leaves the editor
        // open, saying why.
        if let error = state.writeError {
          state.editor?.saveError = error.localizedDescription
          state.writeError = nil
        } else if state.unsaved.count == writes {
          state.editor?.saveError = "The card couldn't be saved."
        } else {
          state.editor = nil
        }
        return effect

      case .editor(.presented(.delegate(.delete))):
        guard let id = state.editor?.cardID else { return .none }
        state.editor = nil
        return .send(.deleteCard(id: id))

      case .editor, .alert:
        return .none
      }
    }
    .ifLet(\.$editor, action: \.editor) {
      CardEditorFeature()
        .dependency(\.cardFilterChoices, .healthDatabase)
    }
    .ifLet(\.$alert, action: \.alert)
  }

  /// An agent's card write (851-4014), on the cards as they show, with what's not yet stored: shown
  /// and queued like the editor's, or answered at once when it's refused or changes nothing.
  private func perform(_ agent: State.AgentRequest, _ state: inout State) -> Effect<Action> {
    let cards = Array(state.cards)
    let now = now
    var write: State.Write
    do throws(CardWriteError) {
      switch agent.request.action {
      case .createCard(let spec):
        let id = withRandomNumberGenerator { CardID.make(at: now, using: &$0) }
        let card = try Card.new(spec, after: cards, id: id, now: now)
        write = State.Write(mutations: [], upserted: [card], answer: .card(id: id))
      case .updateCard(let id, let spec):
        guard let card = state.cards[id: id] else { throw .notFound }
        write = State.Write(
          mutations: [], upserted: [try card.replaced(with: spec, now: now)],
          answer: .card(id: id))
      case .deleteCard(let id):
        guard let card = state.cards[id: id] else { throw .notFound }
        write = State.Write(mutations: [card.delete], deleted: [id])
      case .reorderCards(let ids):
        let moved = try Card.reordering(cards, to: ids, now: now)
        guard !moved.isEmpty else { return Self.answer(agent, .success(.done)) }
        write = State.Write(mutations: [], upserted: moved)
      case .open, .sync, .export:
        return Self.answer(
          agent, .failure(HealthAppActionError.cardNotSaved("That isn't a card change.")))
      }
    } catch {
      return Self.answer(
        agent, .failure(HealthAppActionError.cardNotSaved(Self.agentMessage(error, agent))))
    }
    do {
      write.mutations += try write.upserted.map { try $0.upsert() }
    } catch {
      reportIssue(error)
      return Self.answer(
        agent, .failure(HealthAppActionError.cardNotSaved("lil health couldn't save the card.")))
    }
    write.agent = agent
    return enqueue(write, &state)
  }

  /// Why an agent's write was refused, as the remote server's card tools say it.
  private static func agentMessage(_ error: CardWriteError, _ agent: State.AgentRequest) -> String {
    switch (error, agent.request.action) {
    case (.notFound, .updateCard(let id, _)), (.notFound, .deleteCard(let id)):
      CardWriteError.noCardMessage(id)
    case (.invalidSpec(let errors), _):
      errors.toolMessage
    default:
      error.localizedDescription
    }
  }

  private static func answer(
    _ agent: State.AgentRequest, _ result: Result<HealthAppActionResult, any Error>
  ) -> Effect<Action> {
    .run { _ in agent.request.finish(result) }
  }

  /// Adds a card with `spec` at the end.
  private func create(_ spec: CardSpec, _ state: inout State) -> Effect<Action> {
    guard state.isLoaded else { return .none }
    let now = now
    let id = withRandomNumberGenerator { CardID.make(at: now, using: &$0) }
    let cards = Array(state.cards)
    return write(&state) { () throws(CardWriteError) in
      [try Card.new(spec, after: cards, id: id, now: now)]
    }
  }

  /// Replaces a card's spec, keeping its place.
  private func update(_ id: Card.ID, _ spec: CardSpec, _ state: inout State) -> Effect<Action> {
    guard state.isLoaded else { return .none }
    let card = state.cards[id: id]
    return write(&state) { () throws(CardWriteError) in
      guard let card else { throw .notFound }
      return [try card.edited(spec, now: now)]
    }
  }

  /// The write `change` makes, shown and queued, or `writeError` when it's refused.
  private func write(
    _ state: inout State, _ change: () throws(CardWriteError) -> [Card]
  ) -> Effect<Action> {
    let write: State.Write
    do {
      let cards = try change()
      guard !cards.isEmpty else {
        state.writeError = nil
        return .none
      }
      write = State.Write(mutations: try cards.map { try $0.upsert() }, upserted: cards)
    } catch let error as CardWriteError {
      state.writeError = error
      return .none
    } catch {
      reportIssue(error)
      return .none
    }
    state.writeError = nil
    return enqueue(write, &state)
  }

  /// Shows `write` at once, and pushes it after the writes before it.
  private func enqueue(_ write: State.Write, _ state: inout State) -> Effect<Action> {
    state.cards = State.merged(Array(state.cards), [write])
    state.unsaved.append(write)
    return state.unsaved.count == 1 ? pushNext(state) : .none
  }

  /// Writes the first unsaved write locally and queues it for the server. One that fails locally
  /// is reported, and the cards are read again, so they show what's stored.
  private func pushNext(_ state: State) -> Effect<Action> {
    guard let write = state.unsaved.first else { return .none }
    return .run { [sync] send in
      try await sync.push(write.mutations)
      await send(.pushFinished)
    } catch: { [database] error, send in
      guard !(error is CancellationError) else { return }
      reportIssue(error)
      await send(.pushFailed(try? await database.read { try HealthDatabase.cards($0) }))
    }
    .cancellable(id: CancelID.write)
  }
}

extension CardFilterChoicesClient {
  /// The apps and device models of a type's samples in this Mac's database (`defaultDatabase`, where
  /// the editor asks), as Data Sources reads them.
  static var healthDatabase: Self {
    Self { type in
      @Dependency(\.defaultDatabase) var database
      let sources = try await database.read { try HealthDatabase.sampleSources(of: type, $0) }
      var seen = Set<String>()
      return CardFilterChoices(
        apps: sources.apps.map { CardFilterChoices.App(id: $0.id, name: $0.name) },
        deviceModels: sources.devices.compactMap(\.device.model).filter {
          seen.insert($0).inserted
        })
    }
  }
}
