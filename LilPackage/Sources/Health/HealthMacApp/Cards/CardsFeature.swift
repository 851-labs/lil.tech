public import ComposableArchitecture
public import Foundation
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
    /// Reads the cards, then follows their changes, until cancelled.
    case task
    case cardsLoaded([Card])
    case cardsFailedToLoad(String)
    /// Adds a card with `spec` at the end.
    case createCard(CardSpec)
    /// Replaces a card's spec, keeping its place.
    case updateCard(id: Card.ID, spec: CardSpec)
    case deleteCard(id: Card.ID)
    /// Moves the cards at the offsets to before `toOffset`, as `onMove` gives them.
    case moveCards(fromOffsets: IndexSet, toOffset: Int)
    case moveCardUp(id: Card.ID)
    case moveCardDown(id: Card.ID)
    case writeErrorDismissed
    /// The first unsaved write is in the local table and sync's queue.
    case pushFinished
    /// The first unsaved write failed locally: the cards as stored, read again.
    case pushFailed([Card]?)
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
          for try await cards in HealthDatabase.cardUpdates(in: database) {
            await send(.cardsLoaded(cards))
          }
        } catch: { error, send in
          guard !(error is CancellationError) else { return }
          await send(.cardsFailedToLoad(error.localizedDescription))
        }
        .cancellable(id: CancelID.observation, cancelInFlight: true)

      case .cardsLoaded(let cards):
        state.cards = State.merged(cards, state.unsaved)
        state.isLoading = false
        state.loadFailure = nil
        return .none

      case .cardsFailedToLoad(let message):
        state.isLoading = false
        state.loadFailure = message
        return .none

      case .createCard(let spec):
        guard state.isLoaded else { return .none }
        let now = now
        let id = withRandomNumberGenerator { CardID.make(at: now, using: &$0) }
        let cards = Array(state.cards)
        return write(&state) { () throws(CardWriteError) in
          [try Card.new(spec, after: cards, id: id, now: now)]
        }

      case .updateCard(let id, let spec):
        guard state.isLoaded else { return .none }
        let card = state.cards[id: id]
        return write(&state) { () throws(CardWriteError) in
          guard let card else { throw .notFound }
          return [try card.edited(spec, now: now)]
        }

      case .deleteCard(let id):
        guard state.isLoaded, let card = state.cards[id: id] else { return .none }
        state.writeError = nil
        return enqueue(State.Write(mutations: [card.delete], deleted: [id]), &state)

      case .moveCards(let source, let destination):
        guard state.isLoaded else { return .none }
        let cards = Array(state.cards)
        return write(&state) { () throws(CardWriteError) in
          try Card.moving(cards, fromOffsets: source, toOffset: destination, now: now)
        }

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
        state.unsaved.removeFirst()
        return pushNext(state)

      case .pushFailed(let stored):
        guard !state.unsaved.isEmpty else { return .none }
        state.unsaved.removeFirst()
        if let stored { state.cards = State.merged(stored, state.unsaved) }
        return pushNext(state)
      }
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
