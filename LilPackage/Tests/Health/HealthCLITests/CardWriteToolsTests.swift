import Foundation
import HealthAgentAccess
import HealthCardStore
import HealthCards
import HealthTools
import MCP
import SQLiteData
import Synchronization
import Testing

@testable import HealthCLI

/// The card tools' writes in `lil-health mcp` (851-4014): checked, logged once, then asked of the
/// app through `AgentAccess.sqlite`, and answered from the database once the app has written.
/// Here, a fake app claims the requests and writes the cards into the folder's database, as the
/// app's sync engine would.
@Suite
struct CardWriteToolsTests {
  /// The welcome seed's cards, as sync's first pull brings them.
  private func folder(seeded: Bool = true) throws -> AppFolder {
    let folder = try AppFolder()
    try folder.access.setEnabled(true)
    guard seeded else { return folder }
    try folder.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO "lilSyncState" ("id", "cursor", "epoch", "syncSchema", "entities")
          VALUES (1, 6, 1, 1, 'health_card')
          """)
      try HealthCard.insert {
        for seed in HealthCards.welcomeSeed {
          HealthCard(
            id: seed.id, spec: seed.spec.jsonText, position: seed.position,
            createdAt: 1_792_000_000_000, updatedAt: 1_792_000_000_000, seed: seed.seed)
        }
      }
      .execute(db)
    }
    return folder
  }

  private func cards(_ folder: AppFolder) throws -> [Card] {
    try folder.database.read { try HealthCardStore.cards($0) }
  }

  private let draft: Value = [
    "version": 1, "display": ["name": "Sleeping Heart Rate"],
    "series": [["type": "Heart Rate", "window": ["kind": "asleep"]]], "bucket": "night",
  ]

  @Test(.timeLimit(.minutes(1)))
  func createsUpdatesAndDeletesThroughTheApp() async throws {
    let folder = try folder()
    let app = CardApp(folder)
    let connection = try await MCPConnection(folder.directory, app: app.connection)

    let created = try await connection.call("create_card", ["spec": draft])
    #expect(created.isError == false, "\(created.text)")
    let card = try JSONDecoder().decode(HealthCardResult.self, from: Data(created.text.utf8))
    #expect(card.timeZone == "UTC")
    #expect(card.card.spec["display"]?["name"] == "Sleeping Heart Rate")
    #expect(card.card.position == "a6" && card.card.seed == nil)
    // What the app wrote.
    #expect(try cards(folder).last?.id == card.card.id)

    let renamed: Value = [
      "version": 1, "display": ["name": "Asleep"], "series": [["type": "Heart Rate"]],
    ]
    let updated = try await connection.call(
      "update_card", ["id": .string(card.card.id), "spec": renamed])
    #expect(updated.isError == false, "\(updated.text)")
    let after = try JSONDecoder().decode(HealthCardResult.self, from: Data(updated.text.utf8))
    #expect(after.card.spec["display"]?["name"] == "Asleep" && after.card.position == "a6")

    let deleted = try await connection.call("delete_card", ["id": .string(card.card.id)])
    #expect(deleted.text == #"{"deleted":"\#(card.card.id)"}"#)
    #expect(try cards(folder).count == 6)

    // Each call logged once, with its arguments in short, never the spec; a delete with the
    // card's name, read before it went (851-4011).
    #expect(
      try folder.access.entries().map(\.command) == [
        #"delete_card {"id":"\#(card.card.id)","name":"Asleep"}"#,
        #"update_card {"id":"\#(card.card.id)","name":"Asleep"}"#,
        #"create_card {"name":"Sleeping Heart Rate"}"#,
      ])
    #expect(app.asked.withLock { $0.count } == 3)
    await connection.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func reordersThroughTheApp() async throws {
    let folder = try folder()
    let app = CardApp(folder)
    let connection = try await MCPConnection(folder.directory, app: app.connection)
    let ids = HealthCards.welcomeSeed.map(\.id)
    let order = [ids[5]] + ids[0..<5]

    let result = try await connection.call(
      "reorder_cards", ["ids": .array(order.map(Value.string))])
    #expect(result.isError == false, "\(result.text)")
    let reordered = try JSONDecoder().decode(
      HealthCardOrderResult.self, from: Data(result.text.utf8))
    #expect(reordered.cards.map(\.id) == order)
    // Only the card that moved got a new position.
    #expect(Array(reordered.cards.dropFirst().map(\.position)) == ["a0", "a1", "a2", "a3", "a4"])
    #expect(try folder.access.entries().map(\.command) == [#"reorder_cards {"count":6}"#])
    await connection.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func checksBeforeAskingTheApp() async throws {
    let folder = try folder()
    let app = CardApp(folder)
    let connection = try await MCPConnection(folder.directory, app: app.connection)
    let ids = HealthCards.welcomeSeed.map(\.id)

    for (name, arguments, message): (String, [String: Value], String) in [
      (
        "create_card", ["spec": ["display": ["colour": "red"]]],
        """
        The spec has 4 errors. Fix them and try again:
        - version: version is required: the spec's format, 1.
        - display.name: display.name is required: what the card is called on Summary.
        - display.colour: Unknown field "colour" in display. Allowed: name, symbol, color, unit.
        - series: series is required: 1 to 4 series, e.g. [{"type": "HKQuantityTypeIdentifierHeartRate"}].
        """
      ),
      (
        "create_card", ["spec": "{"],
        "The spec has 1 error. Fix it and try again:\n- spec: The spec isn't valid JSON."
      ),
      (
        "create_card", ["spec": draft, "timeZone": "europe/london"],
        "Unknown time zone: europe/london. Did you mean Europe/London?"
      ),
      (
        "update_card", ["id": "card_nope", "spec": draft],
        #"No card with the id "card_nope". list_cards lists them."#
      ),
      (
        "delete_card", ["id": "card_nope"],
        #"No card with the id "card_nope". list_cards lists them."#
      ),
      (
        "reorder_cards", ["ids": .array([.string(ids[0]), .string(ids[0])])],
        "reorder_cards needs every card's id once: missing "
          + ids.dropFirst().joined(separator: ", ")
          + "; more than once \(ids[0]). list_cards lists them."
      ),
    ] {
      let result = try await connection.call(name, arguments)
      #expect(result.isError == true, "\(name)")
      #expect(result.text == message, "\(name)")
    }
    // None reached the app, and each was logged, as every call is.
    #expect(app.asked.withLock { $0.isEmpty })
    #expect(try folder.access.entries().count == 6)

    // Arguments outside the input schema: the tool's errors too, in the remote server's words,
    // and neither logged nor asked of the app.
    let tooMany = Value.array((0...HealthCards.storeMaxCards).map { .string("card_\($0)") })
    for (name, arguments, message): (String, [String: Value], String) in [
      ("create_card", [:], #"Missing key\#n  at ["spec"]"#),
      ("update_card", ["spec": draft], #"Missing key\#n  at ["id"]"#),
      (
        "update_card", ["timeZone": 1],
        #"Missing key\#n  at ["id"]\#nMissing key\#n  at ["spec"]\#nExpected string\#n  at ["timeZone"]"#
      ),
      ("delete_card", [:], #"Missing key\#n  at ["id"]"#),
      ("reorder_cards", ["ids": "card_a"], #"Expected array\#n  at ["ids"]"#),
      (
        "reorder_cards", ["ids": [1, "card_a", false]],
        #"Expected string\#n  at ["ids"][0]\#nExpected string\#n  at ["ids"][2]"#
      ),
      (
        "reorder_cards", ["ids": tooMany],
        #"Expected a value with a length of at most 200\#n  at ["ids"]"#
      ),
    ] {
      let result = try await connection.call(name, arguments)
      #expect(result.isError == true, "\(name) \(arguments)")
      #expect(result.text == "Invalid parameters for tool '\(name)': " + message, "\(name)")
    }
    #expect(app.asked.withLock { $0.isEmpty })
    #expect(try folder.access.entries().count == 6)
    await connection.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func saysWhatTheAppSaid() async throws {
    let folder = try folder()
    // The app's own refusal (its cards may differ from what this Mac's database has yet).
    let refusing = CardApp(
      folder, refusal: AgentActionFailure(reason: .failed, message: "That card was deleted."))
    let connection = try await MCPConnection(folder.directory, app: refusing.connection)
    let result = try await connection.call("delete_card", ["id": "card_seed_steps"])
    #expect(result.isError == true && result.text == "That card was deleted.")
    await connection.close()

    // No app to ask.
    let alone = try await MCPConnection(folder.directory)
    let missing = try await alone.call("delete_card", ["id": "card_seed_steps"])
    #expect(missing.isError == true && missing.text == "lil health isn't installed.")
    await alone.close()

    // An app that never answers.
    let silent = CardApp(folder, silent: true)
    let waiting = try await MCPConnection(
      folder.directory, app: silent.connection,
      timing: HealthCLI.Timing(claimWait: .milliseconds(200), cardWait: .milliseconds(200)))
    let timedOut = try await waiting.call("delete_card", ["id": "card_seed_steps"])
    #expect(timedOut.text == "lil health didn't answer. Is it installed and signed in?")
    await waiting.close()

    // An app that took it and didn't confirm in time: it may still be saved.
    let slow = CardApp(folder, claimOnly: true)
    let claimed = try await MCPConnection(
      folder.directory, app: slow.connection,
      timing: HealthCLI.Timing(claimWait: .seconds(10), cardWait: .milliseconds(200)))
    let unconfirmed = try await claimed.call("delete_card", ["id": "card_seed_steps"])
    #expect(
      unconfirmed.text
        == "lil health took the change but didn't confirm it in time. It may still be saved: "
        + "check with list_cards before trying again.")
    await claimed.close()
    #expect(try cards(folder).count == 6)
  }

  @Test
  func refusesWhileAccessIsOffOrBeforeTheCardsHaveSynced() async throws {
    let unsynced = try folder(seeded: false)
    let app = CardApp(unsynced)
    let connection = try await MCPConnection(unsynced.directory, app: app.connection)
    let result = try await connection.call("create_card", ["spec": draft])
    #expect(result.text.hasPrefix("lil health hasn't synced the person's cards to this Mac yet."))

    try unsynced.access.setEnabled(false)
    let off = try await connection.call("delete_card", ["id": "card_seed_steps"])
    #expect(off.isError == true && off.text.contains("Allow access on this Mac"))
    #expect(app.asked.withLock { $0.isEmpty })
    await connection.close()
  }
}
