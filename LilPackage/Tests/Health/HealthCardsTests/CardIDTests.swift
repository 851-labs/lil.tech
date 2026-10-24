import Foundation
import Testing

@testable import HealthCards

/// New cards' IDs: `card_` and a ULID, as the store's ID check takes them.
struct CardIDTests {
  @Test
  func aULIDOfTheTimeAndRandomBits() {
    var generator = SystemRandomNumberGenerator()
    // The ULID spec's example time, 1469918176385 ms, is 01ARYZ6S41.
    let id = CardID.make(at: Date(timeIntervalSince1970: 1_469_918_176.385), using: &generator)
    #expect(id.hasPrefix("card_01ARYZ6S41"))
    #expect(id.count == 5 + 26)
    #expect(CardID.isValid(id))
    #expect(
      CardID.make(at: Date(timeIntervalSince1970: 0), using: &generator).hasPrefix(
        "card_0000000000"))
    // Random, so two made in the same millisecond differ.
    let date = Date(timeIntervalSince1970: 1_760_500_000)
    #expect(CardID.make(at: date, using: &generator) != CardID.make(at: date, using: &generator))
    // Ordered by time, as ULIDs are.
    #expect(
      CardID.make(at: date, using: &generator)
        < CardID.make(at: date.addingTimeInterval(0.001), using: &generator))
  }

  @Test
  func validIDsAreTheStores() {
    for id in ["card_01ARYZ6S41TSV4RRFFQ69G5FAV", "card_seed_steps", "card_seed_heart_rate"] {
      #expect(CardID.isValid(id), "\(id)")
    }
    for id in [
      "card_01ARYZ6S41TSV4RRFFQ69G5FA", "card_01ARYZ6S41TSV4RRFFQ69G5FAI",
      "card_01aryz6s41tsv4rrffq69g5fav", "pin_01ARYZ6S41TSV4RRFFQ69G5FAV", "card_seed_",
      "card_seed_Steps", "card_seed_\(String(repeating: "a", count: 41))",
    ] {
      #expect(!CardID.isValid(id), "\(id)")
    }
  }
}
