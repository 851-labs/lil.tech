import Foundation
import HealthAgentAccess
import HealthCardStore
import HealthCards
import SQLiteData
import Synchronization

@testable import HealthCLI

/// lil health, as the card tools see it: running, and answering each request by writing the card
/// into the folder's database, as its sync engine would, unless told to refuse or keep quiet.
final class CardApp: Sendable {
  let folder: AppFolder
  let refusal: AgentActionFailure?
  let silent: Bool
  /// Claims requests and never answers them.
  let claimOnly: Bool
  /// The app's clock.
  let now: Date
  /// A new card's ID, at `now`: the app's are `CardID.make`'s, with random bits.
  let newID: @Sendable (Date) -> String
  /// The actions it was asked for.
  let asked = Mutex<[AgentAction]>([])

  init(
    _ folder: AppFolder, refusal: AgentActionFailure? = nil, silent: Bool = false,
    claimOnly: Bool = false,
    // Tuesday, October 20, 2026, 15:00 UTC.
    now: Date = Date(timeIntervalSince1970: 1_792_508_400),
    newID: @escaping @Sendable (Date) -> String = { _ in "card_01AGENT000000000000000000" }
  ) {
    self.folder = folder
    self.refusal = refusal
    self.silent = silent
    self.claimOnly = claimOnly
    self.now = now
    self.newID = newID
  }

  var connection: HealthCLI.AppConnection {
    HealthCLI.AppConnection(
      isRunning: { true }, signal: { self.respond() }, open: { _ in },
      sleep: { _ in Thread.sleep(forTimeInterval: 0.01) })
  }

  private func respond() {
    guard !silent else { return }
    Thread.detachNewThread { [self] in
      for request in (try? folder.access.claimActions()) ?? [] {
        asked.withLock { $0.append(request.action) }
        guard !claimOnly else { continue }
        let outcome: AgentActionOutcome
        if let refusal {
          outcome = .failed(refusal)
        } else {
          do {
            outcome = .ok(try perform(request.action))
          } catch {
            outcome = .failed(AgentActionFailure(reason: .failed, message: "\(error)"))
          }
        }
        try? folder.access.finish(id: request.id, outcome: outcome)
      }
    }
  }

  private func perform(_ action: AgentAction) throws -> AgentActionResult {
    try folder.database.write { db in
      let cards = try HealthCardStore.cards(db)
      func store(_ card: Card) throws {
        try HealthCard.upsert {
          HealthCard(
            id: card.id, spec: card.storedSpec.text(), position: card.position,
            createdAt: card.createdAt, updatedAt: card.updatedAt, seed: card.seed)
        }
        .execute(db)
      }
      switch action {
      case .createCard(let spec):
        let card = try Card.new(spec, after: cards, id: newID(now), now: now)
        try store(card)
        return .card(id: card.id)
      case .updateCard(let id, let spec):
        guard let card = cards.first(where: { $0.id == id }) else { throw CardWriteError.notFound }
        try store(try card.replaced(with: spec, now: now))
        return .card(id: id)
      case .deleteCard(let id):
        try HealthCard.find(id).delete().execute(db)
        return .done
      case .reorderCards(let ids):
        for card in try Card.reordering(cards, to: ids, now: now) { try store(card) }
        return .done
      case .open, .sync, .export, .downloadBlob:
        return .done
      }
    }
  }
}
