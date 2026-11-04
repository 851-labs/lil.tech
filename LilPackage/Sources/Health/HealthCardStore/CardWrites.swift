public import Foundation
public import HealthCards

// The cards' writes (851-3204, docs/decisions/cards.md, The `health_card` sync entity): each a
// whole row of the card it changes, validated first, with the apps' limits. Pure, so the Mac's
// and the iPhone's features (851-3205), the Mac's local tools (851-3216) and their tests share
// them.

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
  /// A new order that isn't every card once (an agent's `reorder_cards`, 851-4014): the cards it
  /// leaves out, the IDs no card has, and those it gives more than once, each once.
  case notEveryCard(missing: [String], unknown: [String], repeated: [String])

  public var errorDescription: String? {
    switch self {
    case .invalidSpec(let error): error.description
    case .tooManyCards:
      "You have \(HealthCards.maxCards) cards, the most lil health keeps. Delete one first."
    case .notFound: "That card was deleted."
    case .unreadable: "Update lil health to edit this card."
    case .invalidPosition(let message): "The card couldn't be moved: \(message)"
    case .notEveryCard(let missing, let unknown, let repeated):
      // The remote server's words (`CardTools.ts`), for agents.
      "reorder_cards needs every card's id once: "
        + [
          missing.isEmpty ? nil : "missing \(missing.joined(separator: ", "))",
          unknown.isEmpty ? nil : "unknown \(unknown.joined(separator: ", "))",
          repeated.isEmpty ? nil : "more than once \(repeated.joined(separator: ", "))",
        ]
        .compactMap { $0 }.joined(separator: "; ") + ". list_cards lists them."
    }
  }
}

extension CardWriteError {
  /// What the card tools say of an ID no card has, the remote server's words (851-4014).
  public static func noCardMessage(_ id: String) -> String {
    "No card with the id \(CardJSON.string(id).text()). list_cards lists them."
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

  /// The card with its spec replaced by `spec`, validated, keeping its place, creation time and
  /// seed, as an agent's `update_card` does (851-4014): unlike `edited(_:now:)`, also a card whose
  /// spec this version can't read, which replacing is how an agent fixes. Its `updatedAt` never
  /// goes back, as on the remote server.
  public func replaced(with spec: CardSpec, now: Date) throws(CardWriteError) -> Card {
    var card = self
    card.spec = try Self.validated(spec)
    card.storedSpec = card.spec?.json ?? .null
    card.updatedAt = max(now.unixMilliseconds, updatedAt, createdAt)
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

extension Card {
  /// The cards a new order rewrites, with their new positions: `ids` is every card of `cards` once,
  /// in the new order, as an agent's `reorder_cards` gives it (851-4014). As the remote server
  /// does (`reorderedPositions` in `CardTools.ts`), the most cards already in order keep their
  /// positions (the longest run of strictly ascending ones, so ties are told apart), and each of the
  /// others gets one between its new neighbors'. In the new order; empty when nothing moves.
  public static func reordering(
    _ cards: [Card], to ids: [Card.ID], now: Date
  ) throws(CardWriteError) -> [Card] {
    let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    var unknown: [String] = []
    var repeated: [String] = []
    for id in ids {
      if byID[id] == nil {
        if !unknown.contains(id) { unknown.append(id) }
      } else if !seen.insert(id).inserted {
        if !repeated.contains(id) { repeated.append(id) }
      }
    }
    let missing = cards.map(\.id).filter { !seen.contains($0) }
    guard missing.isEmpty, unknown.isEmpty, repeated.isEmpty else {
      throw .notEveryCard(missing: missing, unknown: unknown, repeated: repeated)
    }
    let order = ids.compactMap { byID[$0] }
    func before(_ a: Card, _ b: Card) -> Bool {
      a.position.utf8.lexicographicallyPrecedes(b.position.utf8)
    }

    // The longest strictly ascending run of positions, in O(n²): at most 200 cards.
    var lengths = Array(repeating: 1, count: order.count)
    var previous = Array(repeating: -1, count: order.count)
    var best = -1
    for index in order.indices {
      for earlier in 0..<index
      where before(order[earlier], order[index]) && lengths[earlier] + 1 > lengths[index] {
        lengths[index] = lengths[earlier] + 1
        previous[index] = earlier
      }
      if best == -1 || lengths[index] > lengths[best] { best = index }
    }
    var kept = Set<Int>()
    var index = best
    while index != -1 {
      kept.insert(index)
      index = previous[index]
    }

    let time = now.unixMilliseconds
    var moved: [Card] = []
    var start = 0
    while start < order.count {
      guard !kept.contains(start) else {
        start += 1
        continue
      }
      var end = start
      while end < order.count, !kept.contains(end) { end += 1 }
      let lower = start == 0 ? nil : order[start - 1].position
      let upper = end == order.count ? nil : order[end].position
      let positions: [String]
      do {
        positions = try CardPosition.between(lower, upper, count: end - start)
      } catch {
        throw .invalidPosition(error.message)
      }
      for (card, position) in zip(order[start..<end], positions) {
        var card = card
        card.position = position
        card.updatedAt = max(time, card.updatedAt, card.createdAt)
        moved.append(card)
      }
      start = end
    }
    return moved
  }
}

extension Date {
  /// The date as the cards' times are kept: Unix milliseconds.
  var unixMilliseconds: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}
