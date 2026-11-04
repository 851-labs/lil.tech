import Foundation
import HealthAgentAccess
import HealthCardStore
import HealthCards
import HealthTools
import MCP
import SQLiteData
import Testing

@testable import HealthCLI

// Synthetic data only (AGENTS.md).
private let steps = "HKQuantityTypeIdentifierStepCount"

/// The card tools' reads in `lil-health mcp` (851-3216): `list_cards`, `get_card` and
/// `preview_card` on the cards synced to this Mac, run by its engine, answering and failing as the
/// remote server's (851-3215) do.
@Suite
struct CardToolsTests {
  /// The welcome seed's Steps card, and a card of a later version this one can't read, as sync's
  /// first pull brings them.
  private func addCards(to folder: AppFolder) throws {
    let seed = HealthCards.welcomeSeed[0]
    try folder.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO "lilSyncState" ("id", "cursor", "epoch", "syncSchema", "entities")
          VALUES (1, 6, 1, 1, 'health_card')
          """)
      try HealthCard.insert {
        HealthCard(
          id: seed.id, spec: seed.spec.jsonText, position: seed.position,
          createdAt: 1_792_000_000_000, updatedAt: 1_792_000_000_000, seed: seed.seed)
        HealthCard(
          id: "card_later", spec: #"{"version":3,"display":{"name":"Later"}}"#, position: "a9",
          createdAt: 1_792_000_000_000, updatedAt: 1_792_100_000_000)
      }
      .execute(db)
    }
  }

  @Test
  func listsTheCardsInSummarysOrder() async throws {
    let folder = try AppFolder()
    try addCards(to: folder)
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory, timeZone: "Europe/London")

    let result = try await connection.call("list_cards")
    #expect(result.isError == false, "\(result.text)")
    let listed = try JSONDecoder().decode(HealthCardsResult.self, from: Data(result.text.utf8))
    #expect(listed.timeZone == "Europe/London")
    #expect(listed.cards.map(\.id) == ["card_seed_steps", "card_later"])
    let steps = try #require(listed.cards.first)
    #expect(steps.spec == HealthCards.welcomeSeed[0].spec.json)
    #expect(steps.seed == "steps" && steps.position == "a0")
    // Local times with their offset, in the call's time zone (British Summer Time then).
    #expect(steps.createdAt == "2026-10-14T18:46:40+01:00")
    // Every field there, keys sorted, as `--json` writes them.
    #expect(result.text.hasPrefix(#"{"cards":[{"createdAt":"#))
    #expect(result.text.contains(#""spec":{"bucket":"auto","chart":{"goal":null,"style":"bars"}"#))
    #expect(result.text.contains(#""seed":null"#))
    // A later version's spec comes as it's stored.
    #expect(listed.cards[1].spec["version"] == .number(3))
    await connection.close()
  }

  @Test
  func getsACardsData() async throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try addCards(to: folder)
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)

    // Its own range (W), the calendar week containing today, from Monday.
    let week = try await connection.call("get_card", ["id": "card_seed_steps"])
    #expect(week.isError == false, "\(week.text)")
    let thisWeek = try JSONDecoder().decode(HealthCardDataResult.self, from: Data(week.text.utf8))
    #expect(thisWeek.card.id == "card_seed_steps")
    #expect(thisWeek.data.range == "W" && thisWeek.data.grain == "day")
    #expect(thisWeek.data.start == "2026-10-19" && thisWeek.data.end == "2026-10-25")
    #expect(thisWeek.data.timeZone == "UTC" && thisWeek.data.firstWeekday == "monday")
    #expect(thisWeek.data.series.first?.points.map(\.value) == [3200])
    #expect(thisWeek.data.series.first?.points.first?.readings == nil)
    #expect(week.text.contains(#""readings":null"#))

    // Another week, from Sunday.
    let earlier = try await connection.call(
      "get_card", ["id": "card_seed_steps", "date": "2026-10-15", "firstWeekday": "sunday"])
    let lastWeek = try JSONDecoder().decode(
      HealthCardDataResult.self, from: Data(earlier.text.utf8))
    #expect(lastWeek.data.start == "2026-10-11" && lastWeek.data.end == "2026-10-17")
    #expect(lastWeek.data.series.first?.points.map(\.value) == [4000, 1500, 7000])
    #expect(
      lastWeek.data.series.first?.points.first?.start == "2026-10-14T00:00:00+00:00")

    // A range of the card's bucket's.
    let year = try await connection.call("get_card", ["id": "card_seed_steps", "range": "Y"])
    #expect(year.isError == false)
    #expect(year.structuredContent?.objectValue?["data"]?.objectValue?["grain"] == "month")
    await connection.close()
  }

  @Test
  func getCardsFailuresAreTheRemoteServers() async throws {
    let folder = try AppFolder()
    try addCards(to: folder)
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)

    for (arguments, message): ([String: Value], String) in [
      (["id": "card_nope"], #"No card with the id "card_nope". list_cards lists them."#),
      (
        ["id": "card_later"],
        "This card's spec is version 3, which this version of lil health can't run. Replace it "
          + "with update_card, or ask the person to update lil health."
      ),
      (
        ["id": "card_seed_steps", "date": "2026-02-31"],
        "Unknown date: 2026-02-31. Use a day that exists, as YYYY-MM-DD."
      ),
      (
        ["id": "card_seed_steps", "timeZone": "europe/london"],
        "Unknown time zone: europe/london. Did you mean Europe/London?"
      ),
    ] {
      let result = try await connection.call("get_card", arguments)
      #expect(result.isError == true && result.text == message, "\(arguments)")
    }
    // Arguments outside the input schema: the tool's errors too, in the remote server's words.
    let weekdays =
      #"Expected "sunday" | "monday" | "tuesday" | "wednesday" | "thursday" | "friday" | "saturday""#
    for (arguments, message): ([String: Value], String) in [
      ([:], #"Missing key\#n  at ["id"]"#),
      (["id": 1], #"Expected string\#n  at ["id"]"#),
      (
        ["id": "card_seed_steps", "range": "w"],
        #"Expected "D" | "W" | "M" | "6M" | "Y"\#n  at ["range"]"#
      ),
      (
        ["id": "card_seed_steps", "firstWeekday": "Monday"], weekdays + #"\#n  at ["firstWeekday"]"#
      ),
    ] {
      let result = try await connection.call("get_card", arguments)
      #expect(result.isError == true, "\(arguments)")
      #expect(result.text == "Invalid parameters for tool 'get_card': " + message, "\(arguments)")
    }
    await connection.close()
  }

  @Test
  func previewsADraftWithoutSavingIt() async throws {
    let folder = try AppFolder()
    try folder.addSteps()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)

    let draft: Value = [
      "version": 1, "display": ["name": "  Daily Steps "],
      "series": [["type": "Steps"]], "bucket": "day", "range": "M",
    ]
    let result = try await connection.call("preview_card", ["spec": draft, "date": "2026-10-20"])
    #expect(result.isError == false, "\(result.text)")
    let preview = try JSONDecoder().decode(
      HealthCardPreviewResult.self, from: Data(result.text.utf8))
    // Canonical: trimmed, the type by its identifier, every default filled in.
    #expect(preview.spec["display"]?["name"] == "Daily Steps")
    #expect(
      preview.spec["series"] == [
        [
          "id": "a", "type": .string(steps), "aggregation": "sum",
          "window": nil, "filter": nil, "label": nil, "hidden": false,
        ]
      ])
    #expect(preview.data.range == "M" && preview.data.start == "2026-10-01")
    #expect(preview.data.series.first?.points.map(\.value) == [4000, 1500, 7000, 3200])
    #expect(try await folder.database.read { try HealthCard.fetchCount($0) } == 0)

    // As JSON text, as some agents send it.
    let text = try await connection.call(
      "preview_card",
      ["spec": .string(#"{"version":1,"display":{"name":"Steps"},"series":[{"type":"Steps"}]}"#)])
    #expect(text.isError == false, "\(text.text)")
    #expect(text.structuredContent?.objectValue?["data"]?.objectValue?["range"] == "W")
    await connection.close()
  }

  @Test
  func previewListsEveryErrorOfASpec() async throws {
    let folder = try AppFolder()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)

    let result = try await connection.call(
      "preview_card",
      ["spec": ["version": 1, "display": ["colour": "red"], "series": [["type": "Steps"]]]])
    #expect(result.isError == true)
    #expect(
      result.text == """
        The spec has 2 errors. Fix them and try again:
        - display.name: display.name is required: what the card is called on Summary.
        - display.colour: Unknown field "colour" in display. Allowed: name, symbol, color, unit.
        """)

    let notJSON = try await connection.call("preview_card", ["spec": "{"])
    #expect(
      notJSON.text
        == "The spec has 1 error. Fix it and try again:\n- spec: The spec isn't valid JSON.")
    let notAnObject = try await connection.call("preview_card", ["spec": 3])
    #expect(notAnObject.text.hasPrefix("The spec has 1 error. Fix it and try again:\n- spec: "))

    let range = try await connection.call(
      "preview_card",
      [
        "spec": [
          "version": 1, "display": ["name": "Steps"], "series": [["type": "Steps"]],
          "bucket": "hour", "range": "D",
        ],
        "range": "Y",
      ])
    #expect(
      range.text
        == #"range "Y" doesn't fit the card's bucket "hour". Use D, W, or leave range out for the card's own (D)."#
    )
    let missing = try await connection.call("preview_card", [:])
    #expect(missing.isError == true)
    #expect(
      missing.text == #"Invalid parameters for tool 'preview_card': Missing key\#n  at ["spec"]"#)
    await connection.close()
  }

  @Test
  func logsEachCallWithoutTheSpec() async throws {
    let folder = try AppFolder()
    try addCards(to: folder)
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)

    _ = try await connection.call("list_cards")
    _ = try await connection.call("get_card", ["id": "card_seed_steps", "range": "M"])
    _ = try await connection.call(
      "preview_card",
      ["spec": ["version": 1, "display": ["name": "Private"], "series": [["type": "Heart Rate"]]]])
    // With errors, the series' types the catalog knows.
    _ = try await connection.call(
      "preview_card",
      [
        "spec": [
          "display": ["name": "Private"], "series": [["type": "Heart Rate"], ["type": "Nope"]],
        ],
        "range": "D",
      ])
    #expect(
      try folder.access.entries().map(\.command) == [
        #"preview_card {"range":"D","types":["HKQuantityTypeIdentifierHeartRate"]}"#,
        #"preview_card {"range":"W","types":["HKQuantityTypeIdentifierHeartRate"]}"#,
        #"get_card {"id":"card_seed_steps","range":"M"}"#,
        "list_cards",
      ])
    await connection.close()
  }

  /// Before sync has pulled the cards, an empty table doesn't mean there are none.
  @Test
  func saysWhenTheCardsHaventSyncedYet() async throws {
    let folder = try AppFolder()
    try folder.access.setEnabled(true)
    let connection = try await MCPConnection(folder.directory)
    let message =
      "lil health hasn't synced the person's cards to this Mac yet. Ask them to open lil health "
      + "and sign in, then try again."
    for (name, arguments): (String, [String: Value]) in [
      ("list_cards", [:]), ("get_card", ["id": "card_seed_steps"]),
    ] {
      let result = try await connection.call(name, arguments)
      #expect(result.isError == true && result.text == message, "\(name)")
    }
    await connection.close()
  }

  @Test
  func refusesWhileAccessIsOff() async throws {
    let folder = try AppFolder()
    try addCards(to: folder)
    let connection = try await MCPConnection(folder.directory)
    for (name, arguments): (String, [String: Value]) in [
      ("list_cards", [:]), ("get_card", ["id": "card_seed_steps"]),
      ("preview_card", ["spec": ["version": 1]]),
    ] {
      let result = try await connection.call(name, arguments)
      #expect(result.isError == true && result.text.contains("Allow access on this Mac"), "\(name)")
    }
    await connection.close()
  }
}
