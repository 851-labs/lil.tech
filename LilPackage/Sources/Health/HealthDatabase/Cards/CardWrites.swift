public import Foundation
public import HealthCards

// The cards' writes (851-3204, docs/decisions/cards.md, The `health_card` sync entity): each a
// whole row of the card it changes, validated first, with the apps' limits. Pure, so the Mac's
// feature, its local tools (851-3216) and their tests share them.

/// Why a card couldn't be written.
public enum CardWriteError: Error, Equatable, Sendable, LocalizedError {
  /// The spec isn't valid, or is over the apps' 8 KB: every error, for the editor's fields.
  case invalidSpec(CardSpecValidationError)
  /// The account has `HealthCards.maxCards` already.
  case tooManyCards
  /// No card has the ID: another device or an agent deleted it.
  case notFound
  /// This version can't read the card's spec, so it can't edit it.
  case unreadable
  /// A position around it isn't a valid fractional index, which the store never keeps.
  case invalidPosition(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSpec(let error): error.description
    case .tooManyCards:
      "You have \(HealthCards.maxCards) cards, the most lil health keeps. Delete one first."
    case .notFound: "That card was deleted."
    case .unreadable: "Update lil health to edit this card."
    case .invalidPosition(let message): "The card couldn't be moved: \(message)"
    }
  }
}

extension Card {
  /// A new card at the end of `cards` (Summary's order), with `spec` validated as apps write it
  /// (`CardSpec(input:)`: canonical, at most 8 KB), refused past `HealthCards.maxCards`.
  public static func new(
    _ spec: CardSpec, after cards: [Card], id: String, now: Date
  ) throws(CardWriteError) -> Card {
    guard cards.count < HealthCards.maxCards else { throw .tooManyCards }
    let spec = try validated(spec)
    let position: String
    do {
      position = try CardPosition.between(cards.last?.position, nil)
    } catch {
      throw .invalidPosition(error.message)
    }
    let time = now.unixMilliseconds
    return Card(id: id, spec: spec, position: position, createdAt: time, updatedAt: time)
  }

  /// The card with `spec`, validated, keeping its place, creation time and seed.
  public func edited(_ spec: CardSpec, now: Date) throws(CardWriteError) -> Card {
    guard self.spec != nil else { throw .unreadable }
    var card = self
    card.spec = try Self.validated(spec)
    card.storedSpec = card.spec?.json ?? .null
    card.updatedAt = max(now.unixMilliseconds, createdAt)
    return card
  }

  private static func validated(_ spec: CardSpec) throws(CardWriteError) -> CardSpec {
    do {
      return try CardSpec(input: spec.json)
    } catch {
      throw .invalidSpec(error)
    }
  }

  /// The cards a move rewrites, with their new positions: those at `source` (offsets into `cards`,
  /// in Summary's order) moved to before `destination`, as SwiftUI's `onMove` gives them. Each
  /// gets a position between its new neighbors', so the others keep theirs: one write per moved
  /// card, never a renumbering. Cards after them with the same position as the one before them
  /// (two devices adding at once) can't be placed after it, so they're rewritten too. Empty when
  /// nothing moves.
  public static func moving(
    _ cards: [Card], fromOffsets source: IndexSet, toOffset destination: Int, now: Date
  ) throws(CardWriteError) -> [Card] {
    let source = source.filter(cards.indices.contains)
    guard !source.isEmpty, (0...cards.count).contains(destination) else { return [] }
    let moved = source.map { cards[$0] }
    var order = cards.enumerated().filter { !source.contains($0.offset) }.map(\.element)
    let start = destination - source.count(where: { $0 < destination })
    order.insert(contentsOf: moved, at: start)
    guard order.map(\.id) != cards.map(\.id) else { return [] }

    let lower = start > 0 ? order[start - 1].position : nil
    var end = start + moved.count
    if let lower {
      while end < order.count, !lower.utf8.lexicographicallyPrecedes(order[end].position.utf8) {
        end += 1
      }
    }
    let upper = end < order.count ? order[end].position : nil
    let positions: [String]
    do {
      positions = try CardPosition.between(lower, upper, count: end - start)
    } catch {
      throw .invalidPosition(error.message)
    }
    let time = now.unixMilliseconds
    return zip(order[start..<end], positions).map { card, position in
      var card = card
      card.position = position
      card.updatedAt = max(time, card.createdAt)
      return card
    }
  }
}
