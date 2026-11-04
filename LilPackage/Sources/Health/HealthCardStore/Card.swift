import Foundation
public import HealthCards
public import LilSync
import OpenAPIRuntime

// Summary's cards (851-3204, docs/decisions/cards.md): read from the synced `healthCards` table,
// and written through sync (`SyncClient.push`) as whole rows, one card per write, so the last
// writer wins per card. The Mac and the iPhone share them (851-3205).

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
    id = record.id
    storedSpec = (try? CardJSON(parsing: Data(record.spec.utf8))) ?? .null
    spec = try? CardSpec(stored: storedSpec)
    position = record.position
    createdAt = record.createdAt
    updatedAt = record.updatedAt
    seed = record.seed
  }

  /// The card's whole row, as ``HealthCardStore/syncEntity`` stores it and the server takes it:
  /// every field, `seed` included as `null`, since `health_card` takes whole rows only. Throws
  /// ``CardWriteError/unreadable`` for a card without a spec to write back, which the store would
  /// refuse.
  public func upsert() throws -> SyncMutation {
    guard storedSpec != .null else { throw CardWriteError.unreadable }
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

extension Card {
  /// The card's name, as far as this version can read its stored spec, else "Card": a card of a
  /// later version's too.
  public var storedName: String {
    if let spec { return spec.display.name }
    if case .string(let name)? = storedSpec["display"]?["name"] { return name }
    return "Card"
  }
}

extension Card {
  /// The welcome seed's cards, as an account has them once synced: Summary's rows while its cards
  /// load, on the Mac and the iPhone.
  public static let welcomeSeed: [Card] = HealthCards.welcomeSeed.map {
    Card(
      id: $0.id, spec: $0.spec, position: $0.position, createdAt: 0, updatedAt: 0, seed: $0.seed)
  }
}
