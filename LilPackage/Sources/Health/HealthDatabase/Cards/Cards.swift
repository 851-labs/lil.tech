import Foundation
import GRDB
public import HealthCards
public import LilSync
import OpenAPIRuntime
public import SQLiteData

// Summary's cards on the Mac (851-3204, docs/decisions/cards.md): read from the synced
// `healthCards` table, and written through sync (`SyncClient.push`) as whole rows, one card per
// write, so the last writer wins per card.

/// One of the account's cards, as features show and write it: a ``HealthCard`` record with its
/// spec read.
public struct Card: Equatable, Identifiable, Sendable {
  /// `card_` and a ULID, or a seed card's fixed ID.
  public let id: String
  /// What the card charts, or `nil` when this version of lil health can't read its spec (a later
  /// version's): Summary shows "Update lil health to show this card".
  public var spec: CardSpec?
  /// The spec as stored, written back as it is when the card moves, so a later version's spec
  /// survives this version moving it.
  public var storedSpec: CardJSON
  /// Summary's order (`CardPosition`), ascending, ties by ID.
  public var position: String
  /// Unix milliseconds.
  public var createdAt: Int
  /// Unix milliseconds, set by every write.
  public var updatedAt: Int
  /// The seed card it started as (`steps`), else `nil`. Kept through edits and moves.
  public var seed: String?

  public init(
    id: String, spec: CardSpec, position: String, createdAt: Int, updatedAt: Int,
    seed: String? = nil
  ) {
    self.id = id
    self.spec = spec
    self.storedSpec = spec.json
    self.position = position
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.seed = seed
  }

  /// A stored card. A spec this version can't read (a later version's, or one it can't parse)
  /// leaves `spec` `nil`.
  public init(_ record: HealthCard) {
    let text = Data(record.spec.utf8)
    id = record.id
    spec = try? JSONDecoder().decode(CardSpec.self, from: text)
    storedSpec = (try? CardJSON(parsing: text)) ?? .null
    position = record.position
    createdAt = record.createdAt
    updatedAt = record.updatedAt
    seed = record.seed
  }

  /// The card's whole row, as ``HealthDatabase/syncEntities`` stores it and the server takes it:
  /// every field, `seed` included as `null`, since `health_card` takes whole rows only.
  public func upsert() throws -> SyncMutation {
    let spec = try JSONDecoder().decode(
      OpenAPIValueContainer.self, from: Data(storedSpec.text().utf8))
    let row = try OpenAPIObjectContainer(unvalidatedValue: [
      "spec": spec.value, "position": position, "createdAt": createdAt, "updatedAt": updatedAt,
      "seed": seed,
    ])
    return .upsert(Self.entity, id: id, row: row)
  }

  /// Deletes the card, on every device.
  public var delete: SyncMutation { .delete(Self.entity, id: id) }

  /// The sync entity.
  public static let entity = "health_card"

  /// Whether `self` comes before `other` in Summary's order: by position, then ID, each by its
  /// bytes, as SQLite's BINARY collation and the server order them.
  public func precedes(_ other: Card) -> Bool {
    if position != other.position {
      return position.utf8.lexicographicallyPrecedes(other.position.utf8)
    }
    return id.utf8.lexicographicallyPrecedes(other.id.utf8)
  }
}

extension HealthDatabase {
  /// The account's cards, in Summary's order.
  public static func cards(_ db: Database) throws -> [Card] {
    try HealthCard.order { ($0.position, $0.id) }.fetchAll(db).map(Card.init)
  }

  /// The cards now, then each time they change: this Mac's writes, and other devices' and agents'
  /// as sync brings them.
  public static func cardUpdates(
    in database: any DatabaseReader
  ) -> AsyncThrowingStream<[Card], any Error> {
    let values = ValueObservation.tracking(cards).removeDuplicates().values(in: database)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await cards in values { continuation.yield(cards) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
