import Testing

@testable import HealthCards

/// Fractional-index positions, as the `fractional-indexing` package (3.4.0) makes them. Its own
/// outputs for the shared cases were checked against the package when they were written.
struct CardPositionTests {
  @Test
  func firstAndAfter() throws {
    #expect(try CardPosition.between(nil, nil) == "a0")
    #expect(try CardPosition.between("a0", nil) == "a1")
    #expect(try CardPosition.between("az", nil) == "b00")
    #expect(try CardPosition.between("Zz", nil) == "a0")
    #expect(try CardPosition.between(nil, "a0") == "Zz")
    #expect(try CardPosition.between(nil, "a0V") == "a0")
  }

  @Test
  func between() throws {
    #expect(try CardPosition.between("a0", "a1") == "a0V")
    #expect(try CardPosition.between("a1", "a0") == "a0V")
    #expect(try CardPosition.between("a0", "a0V") == "a0G")
    #expect(try CardPosition.between("a0V", "a1") == "a0l")
    #expect(try CardPosition.between("a0V", "a0W") == "a0VV")
  }

  @Test
  func invalid() {
    for (a, b) in [("a0", "a0"), ("a00", nil), ("", nil), ("b1", nil), (nil, "a")]
      as [(String?, String?)]
    {
      #expect(throws: CardPosition.InvalidPosition.self, "\(a ?? "nil") \(b ?? "nil")") {
        try CardPosition.between(a, b)
      }
    }
  }

  @Test
  func manyBetween() throws {
    #expect(try CardPosition.between(nil, nil, count: 6) == ["a0", "a1", "a2", "a3", "a4", "a5"])
    #expect(try CardPosition.between(nil, nil, count: 0) == [])
    let keys = try CardPosition.between("a0", "a1", count: 5)
    #expect(keys == keys.sorted() && Set(keys).count == 5)
    #expect(keys.allSatisfy { $0 > "a0" && $0 < "a1" })
  }

  /// Moving cards around keeps every position between its neighbors', and short.
  @Test
  func repeatedMovesStayOrdered() throws {
    var positions = try CardPosition.between(nil, nil, count: 6)
    var generator = SplitMix(seed: 3194)
    for _ in 0..<2_000 {
      let from = Int(generator.next() % UInt64(positions.count))
      let moved = positions.remove(at: from)
      let to = Int(generator.next() % UInt64(positions.count + 1))
      let before = to > 0 ? positions[to - 1] : nil
      let after = to < positions.count ? positions[to] : nil
      let position = try CardPosition.between(before, after)
      #expect(before.map { $0 < position } ?? true)
      #expect(after.map { position < $0 } ?? true)
      #expect(CardPosition.error(position) == nil)
      positions.insert(position, at: to)
      _ = moved
    }
    #expect(positions == positions.sorted())
    #expect(positions.allSatisfy { $0.count < 40 })
  }

  /// Into one gap, again and again: about a character every 6 moves.
  @Test
  func oneGapGrowsSlowly() throws {
    var lower = "a0"
    let upper = "a1"
    for _ in 0..<60 {
      lower = try CardPosition.between(lower, upper)
    }
    #expect(lower.count <= 14)
  }

  @Test
  func validity() {
    #expect(CardPosition.error("a0") == nil)
    #expect(CardPosition.error("a0V") == nil)
    #expect(CardPosition.error("")?.code == .positionLength)
    #expect(CardPosition.error(String(repeating: "a", count: 201))?.code == .positionLength)
    #expect(CardPosition.error("")?.message == "position must be 1 to 200 characters.")
    #expect(CardPosition.error("a00")?.code == .invalidPosition)
    #expect(CardPosition.error("a0!")?.code == .invalidPosition)
    #expect(
      CardPosition.error("b1")?.message
        == #"position "b1" isn't a fractional index: base-62 digits, starting with a letter that gives the length of its integer part."#
    )
  }
}

/// A seeded generator, so the moves are the same every run.
private struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
