import Foundation
import HealthAgentAccess
import HealthCards
import HealthConformance
import MCP
import Testing

@testable import HealthCLI

/// The Mac's side of the card tools' conformance cases (851-3217, docs/decisions/cards.md › MCP
/// tools): the same calls as the remote MCP server's
/// (`Services/api/test/health/cards/CardToolConformance.test.ts`) must give the same outputs and
/// errors, word for word. The account (the cards' conformance dataset, the welcome seed as the
/// store seeds it, and the file's cards as a Mac pushed them) is synced into a fresh database with
/// the app's sync engine, then each case's calls go through `lil-health mcp`'s server in order,
/// with a stand-in for the app (`CardApp`) answering the writes as the app does, through the same
/// `HealthCardStore` writes.
@Suite
struct CardToolConformanceTests {
  /// The file, read once.
  static let file = Result { try CardToolCases.read() }

  @Test(arguments: try file.get().cases)
  func conformanceCase(_ testCase: CardToolCases.Case) async throws {
    let folder = try AppFolder()
    try await Conformance.sync(
      try ConformanceBatch.read(ConformanceFiles.cards.appending(path: "dataset.json")),
      into: folder.database, cards: try Self.file.get().cardRows())
    try folder.access.setEnabled(true)
    let now = try Conformance.date(testCase.now)
    let app = CardApp(
      folder, now: now,
      newID: { now in
        var generator = SystemRandomNumberGenerator()
        return CardID.make(at: now, using: &generator)
      })
    // In UTC, the remote server's default, as the Health tools' cases are.
    let connection = try await MCPConnection(
      folder.directory, now: now, timeZone: "UTC", app: app.connection)

    do {
      try await run(testCase, now: now, on: connection)
    } catch {
      await connection.close()
      throw error
    }
    await connection.close()
  }

  /// A case's calls, in order, each answer compared with its expected one.
  private func run(_ testCase: CardToolCases.Case, now: Date, on connection: MCPConnection)
    async throws
  {
    var made: String?
    for (index, call) in testCase.calls.enumerated() {
      let label = "\(testCase.name), call \(index + 1), \(call.tool)"
      guard case .object(let arguments) = call.arguments.replacingNewCard(with: made) else {
        Issue.record("\(label): arguments aren't an object")
        break
      }
      let result = try await connection.call(call.tool, arguments.mapValues(Value.init))
      if let message = call.expectedError {
        #expect(result.isError == true, "\(label): \(result.text)")
        #expect(result.text == message, "\(label)")
        continue
      }
      #expect(result.isError == false, "\(label): \(result.text)")
      let output = try JSONDecoder().decode(
        ConformanceJSON.self, from: JSONEncoder().encode(result.structuredContent))
      // The output as structured content, and the same as text.
      #expect(
        try JSONDecoder().decode(ConformanceJSON.self, from: Data(result.text.utf8)) == output,
        "\(label)")
      let expected = try #require(call.expected)
      if made == nil, let id = expected.newCard(in: output) {
        // A new card's ID: a ULID of now.
        #expect(CardID.isValid(id) && !id.hasPrefix("card_seed_"), "\(label): \(id)")
        var zero = ZeroGenerator()
        #expect(
          id.dropLast(16) == CardID.make(at: now, using: &zero).dropLast(16), "\(label): \(id)")
        made = id
      }
      let resolved = expected.replacingNewCard(with: made)
      #expect(output.matches(resolved), "\(label)\n\(output.text)\nexpected:\n\(resolved.text)")
    }
  }
}

/// The card tools' conformance file, `Services/api/test/health/cards/tool-conformance/cases.json`.
struct CardToolCases: Decodable, Sendable {
  /// When the store seeded the welcome cards.
  var seededAt: String
  /// The account's other cards, as a Mac pushed them.
  var cards: [StoredCard]
  var cases: [Case]

  struct StoredCard: Decodable, Sendable {
    var id: String
    /// As a spec input: canonicalized before it's stored.
    var spec: ConformanceJSON
    var position: String
    var createdAt: String
    var updatedAt: String
  }

  struct Case: Decodable, Sendable, CustomTestStringConvertible {
    var name: String
    var note: String?
    var now: String
    var calls: [Call]

    var testDescription: String { name }
  }

  struct Call: Decodable, Sendable {
    var tool: String
    var arguments: ConformanceJSON
    var expected: ConformanceJSON?
    /// The tool's error message, word for word.
    var expectedError: String?
  }

  static func read() throws -> CardToolCases {
    try JSONDecoder().decode(
      CardToolCases.self,
      from: Data(
        contentsOf: ConformanceFiles.cards.deletingLastPathComponent()
          .appending(path: "tool-conformance/cases.json")))
  }

  /// Every card's whole row, as the store's change feed has them: the welcome seed's, written
  /// when it seeded, then the file's, their specs canonical.
  func cardRows() throws -> [(id: String, row: [String: Any])] {
    let seededAt = try Self.milliseconds(seededAt)
    let seed = HealthCards.welcomeSeed.map { card in
      (
        id: card.id,
        row: [
          "spec": card.spec.json, "position": card.position, "createdAt": seededAt,
          "updatedAt": seededAt, "seed": card.seed,
        ] as [String: Any]
      )
    }
    let others = try cards.map { card in
      let input = try CardJSON(parsing: JSONEncoder().encode(card.spec))
      return (
        id: card.id,
        row: [
          "spec": try CardSpec(input: input).json, "position": card.position,
          "createdAt": try Self.milliseconds(card.createdAt),
          "updatedAt": try Self.milliseconds(card.updatedAt), "seed": NSNull(),
        ] as [String: Any]
      )
    }
    return try (seed + others).map { card in
      var row = card.row
      // As JSON, for the change feed's page.
      if let spec = row["spec"] as? CardJSON {
        row["spec"] = try JSONSerialization.jsonObject(with: Data(spec.text().utf8))
      }
      return (card.id, row)
    }
  }

  private static func milliseconds(_ iso: String) throws -> Int {
    Int((try Conformance.date(iso).timeIntervalSince1970 * 1000).rounded())
  }
}

/// Where a card made in a case goes in its expected outputs and later calls' arguments.
private let newCardMarker = "<new card>"

extension ConformanceJSON {
  /// As JSON text, keys sorted, to show a difference.
  var text: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "\(self)"
  }

  /// `self` with every `<new card>` replaced by `id`, if there's one.
  func replacingNewCard(with id: String?) -> ConformanceJSON {
    switch self {
    case .string(newCardMarker): id.map(ConformanceJSON.string) ?? self
    case .array(let values): .array(values.map { $0.replacingNewCard(with: id) })
    case .object(let values): .object(values.mapValues { $0.replacingNewCard(with: id) })
    default: self
    }
  }

  /// The ID `actual` has where `self` says `<new card>`, if any: the first, depth first, keys
  /// sorted, as the server's side walks them.
  func newCard(in actual: ConformanceJSON) -> String? {
    switch (self, actual) {
    case (.string(newCardMarker), .string(let id)): return id
    case (.array(let expected), .array(let actual)):
      return zip(expected, actual).lazy.compactMap { $0.newCard(in: $1) }.first
    case (.object(let expected), .object(let actual)):
      return expected.keys.sorted().lazy.compactMap { key in
        actual[key].flatMap { expected[key]!.newCard(in: $0) }
      }.first
    default: return nil
    }
  }
}

/// Random bits that are all zero, for the time part of a ULID.
private struct ZeroGenerator: RandomNumberGenerator {
  mutating func next() -> UInt64 { 0 }
}
