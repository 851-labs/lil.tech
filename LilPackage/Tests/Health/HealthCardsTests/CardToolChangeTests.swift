import HealthCards
import Testing

/// The access logs' sentences for agents' card writes (851-4011).
struct CardToolChangeTests {
  @Test func saysWhatChangedOnceItWentThrough() {
    #expect(
      CardToolChange.allCases.map { $0.sentence(cardName: "Morning Weight", done: true) } == [
        "Created card “Morning Weight”", "Changed card “Morning Weight”",
        "Deleted card “Morning Weight”", "Reordered cards",
      ])
    #expect(CardToolChange.create.sentence(cardName: nil, done: true) == "Created a card")
  }

  @Test func saysWhatWasAskedOtherwise() {
    #expect(
      CardToolChange.allCases.map { $0.sentence(cardName: "Morning Weight", done: false) } == [
        "Create card “Morning Weight”", "Change card “Morning Weight”",
        "Delete card “Morning Weight”", "Reorder cards",
      ])
    #expect(CardToolChange.delete.sentence(cardName: nil, done: false) == "Delete a card")
  }

  @Test func remoteEntriesAreDoneOnceWritten() {
    func sentence(_ tool: String, _ outcome: String) -> String? {
      CardToolChange.sentence(tool: tool, cardName: "Steps", outcome: outcome)
    }
    #expect(sentence("create_card", "ok") == "Created card “Steps”")
    // Written, though its answer was too large to send.
    #expect(sentence("update_card", "too_large") == "Changed card “Steps”")
    #expect(sentence("delete_card", "error") == "Delete card “Steps”")
    #expect(sentence("reorder_cards", "a_later_outcome") == "Reorder cards")
    // Reads aren't changes.
    #expect(sentence("get_card", "ok") == nil)
    #expect(sentence("preview_card", "ok") == nil)
    #expect(sentence("list_cards", "ok") == nil)
  }

  @Test func readsTheLocalLogsEntries() {
    let created = CardToolChange.logged(#"create_card {"name":"Sleeping Heart Rate"}"#)
    #expect(created?.change == .create && created?.cardName == "Sleeping Heart Rate")
    let updated = CardToolChange.logged(#"update_card {"id":"card_a","name":"Asleep"}"#)
    #expect(updated?.change == .update && updated?.cardName == "Asleep")
    // From before deletes logged the name.
    let deleted = CardToolChange.logged(#"delete_card {"id":"card_a"}"#)
    #expect(deleted?.change == .delete && deleted?.cardName == nil)
    let reordered = CardToolChange.logged(#"reorder_cards {"count":7}"#)
    #expect(reordered?.change == .reorder && reordered?.cardName == nil)
    #expect(CardToolChange.logged("metric Steps --range W") == nil)
    #expect(CardToolChange.logged(#"get_card {"id":"card_a"}"#) == nil)
    #expect(CardToolChange.logged("create_card") != nil)
  }
}
