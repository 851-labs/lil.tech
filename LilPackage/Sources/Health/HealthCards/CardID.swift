public import Foundation

/// A card's ID (docs/decisions/cards.md, The `health_card` sync entity › IDs): `card_` and a ULID,
/// made by whoever creates the card, so cards created on two devices offline never collide. Seed
/// cards have fixed IDs instead (`card_seed_steps`, `HealthCards.welcomeSeed`).
public enum CardID {
  /// Crockford's base 32, a ULID's digits: no I, L, O or U.
  static let digits = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  /// A new card's ID: `card_` and a ULID of `date` (48 bits of Unix milliseconds, 10 digits) and
  /// 80 random bits (16 digits).
  public static func make(at date: Date, using generator: inout some RandomNumberGenerator)
    -> String
  {
    var milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
    milliseconds &= (1 << 48) - 1
    var time: [Character] = []
    for _ in 0..<10 {
      time.append(digits[Int(milliseconds & 31)])
      milliseconds >>= 5
    }
    let random = (0..<16).map { _ in digits[Int.random(in: 0..<32, using: &generator)] }
    return "card_" + String(time.reversed()) + String(random)
  }

  /// Whether `id` is a card's ID the store takes: `card_` and a ULID, or a seed card's.
  public static func isValid(_ id: String) -> Bool {
    guard id.hasPrefix("card_") else { return false }
    let rest = id.dropFirst(5)
    if rest.hasPrefix("seed_") {
      let name = rest.dropFirst(5)
      return (1...40).contains(name.count)
        && name.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }
    return rest.count == 26 && rest.allSatisfy(digits.contains)
  }
}
