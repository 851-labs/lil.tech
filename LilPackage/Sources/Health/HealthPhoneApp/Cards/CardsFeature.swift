public import ComposableArchitecture
public import Foundation
public import HealthCardEditor
public import HealthCardStore
public import HealthCards
import HealthKitAccess
import LilSync
import SQLiteData

/// The account's cards on the iPhone (851-3205, docs/decisions/cards.md): read from the iPhone's
/// card database (`PhoneCards`) in Summary's order, and created, edited, deleted and moved
/// through sync, as the Mac's `CardsFeature` does. Each write is the whole row of the card it
/// changes, written locally and queued for the server (`SyncClient.push`), so it works offline;
/// other devices' and agents' changes arrive as sync pulls them. `AppFeature` keeps it, and syncs
/// the cards while signed in; the screen showing them (Summary, 851-3211) sends ``Action/task``.
///
/// The cards are loading until sync has pulled them once (`LilSyncEngine.holds(_:_:)`), so a new
/// iPhone shows Summary loading rather than empty before its first pull: apps never seed cards,
/// the server does, once per account.
///
/// A write shows at once. Writes go to sync one at a time, in the order they were made, since the
/// server keeps the last to arrive, and each shows over what's read until it's in the local table
/// (``State/unsaved``). Writes are validated as apps write them (`CardSpec(input:)`, at most
/// 8 KB), a 101st card is refused (`HealthCards.maxCards`), and a refused write sets
/// ``State/writeError``. Writes wait for the cards to be read: before then, there's no end to add
/// a card at.
///
/// It presents the card editor (851-3213), the Mac's (`CardEditorFeature`): New Card from Summary,
/// Edit from a card's page or row, and Delete…'s confirmation, from the editor or a row's swipe.
/// Save is a write like the others: the editor closes once it's made, and stays open saying why
/// when it's refused.
@Reducer
public struct CardsFeature {
  @ObservableState
  public struct State: Equatable {
    /// In Summary's order: as last read, with the writes not yet stored over them.
    public var cards: IdentifiedArrayOf<Card>
    /// Whether the cards haven't been read yet, or sync hasn't pulled them since signing in, so
    /// an empty list would be wrong.
    public var isLoading: Bool
    /// Why the cards couldn't be read.
    public var loadFailure: String?
    /// Why the last write was refused, until ``Action/writeErrorDismissed``.
    public var writeError: CardWriteError?
    /// Writes not yet in the local table, oldest first. The first is being pushed.
    var unsaved: [Write] = []
    /// The card editor, for a new card or one of these.
    @Presents public var editor: CardEditorFeature.State?
    /// Delete…'s confirmation, or why a move was refused.
    @Presents public var alert: AlertState<Action.Alert>?

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

    /// One write: the mutations for sync, and the cards they upsert or delete.
    struct Write: Equatable {
      var mutations: [SyncMutation]
      var upserted: [Card] = []
      var deleted: [Card.ID] = []
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
    case alert(PresentationAction<Alert>)
    /// Delete…: its confirmation.
    case deleteCardButtonTapped(id: Card.ID)
    /// Edit…: the editor, for the card.
    case editCardButtonTapped(id: Card.ID)
    case editor(PresentationAction<CardEditorFeature.Action>)
    /// New Card: the editor, for a new card.
    case newCardButtonTapped
    /// Reads the cards, then follows their changes, until cancelled.
    case task
    case cardsLoaded(SyncedCards)
    case cardsFailedToLoad(String)
    /// Adds a card with `spec` at the end.
    case createCard(CardSpec)
    /// Replaces a card's spec, keeping its place.
    case updateCard(id: Card.ID, spec: CardSpec)
    case deleteCard(id: Card.ID)
    /// Moves the cards at the offsets to before `toOffset`, as `onMove` gives them.
    case moveCards(fromOffsets: IndexSet, toOffset: Int)
    case writeErrorDismissed
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
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { [database] send in
          for try await cards in HealthCardStore.syncedCardUpdates(in: database) {
            await send(.cardsLoaded(cards))
          }
        } catch: { error, send in
          guard !(error is CancellationError) else { return }
          await send(.cardsFailedToLoad(error.localizedDescription))
        }
        .cancellable(id: CancelID.observation, cancelInFlight: true)

      case .cardsLoaded(let synced):
        state.cards = State.merged(synced.cards, state.unsaved)
        state.isLoading = !synced.isSynced
        state.loadFailure = nil
        return .none

      case .cardsFailedToLoad(let message):
        state.isLoading = false
        state.loadFailure = message
        return .none

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
        // Rather than the row snapping back without a word.
        if let error = state.writeError {
          state.alert = .cardNotMoved(error)
          state.writeError = nil
        }
        return effect

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

      case .alert(.presented(.confirmDelete(let id))):
        return .send(.deleteCard(id: id))

      case .editor(.presented(.delegate(.save(let spec)))):
        guard let editor = state.editor else { return .none }
        guard state.isLoaded else {
          state.editor?.saveError = "Your cards haven't loaded yet. Try again in a moment."
          return .none
        }
        let writes = state.unsaved.count
        let effect =
          if let id = editor.cardID {
            update(id, editor.written(spec, over: state.cards[id: id]?.spec), &state)
          } else {
            create(spec, &state)
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

      case .writeErrorDismissed:
        state.writeError = nil
        return .none

      case .pushFinished:
        guard !state.unsaved.isEmpty else { return .none }
        state.unsaved.removeFirst()
        return pushNext(state)

      case .pushFailed(let stored):
        guard !state.unsaved.isEmpty else { return .none }
        state.unsaved.removeFirst()
        if let stored { state.cards = State.merged(stored, state.unsaved) }
        return pushNext(state)
      }
    }
    .ifLet(\.$editor, action: \.editor) {
      CardEditorFeature()
        .dependency(\.cardFilterChoices, .healthKit)
    }
    .ifLet(\.$alert, action: \.alert)
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
      await send(.pushFailed(try? await database.read { try HealthCardStore.cards($0) }))
    }
    .cancellable(id: CancelID.write)
  }
}

extension CardFilterChoicesClient {
  /// The apps and device models of a type's samples in this iPhone's HealthKit.
  static var healthKit: Self {
    Self { type in
      @Dependency(\.healthKitCards) var healthKitCards
      return try await healthKitCards.filterChoices(type)
    }
  }
}
