import Foundation

/// A card write an agent made through a card tool, as Settings' access logs say it (851-4011,
/// docs/decisions/cards.md › MCP tools › The access log): "Created card “Morning Weight”". The
/// remote log's rows and the Mac's local log's say it in the same words, so it's in `HealthCards`,
/// which both apps build.
public enum CardToolChange: String, CaseIterable, Sendable {
  case create = "create_card"
  case update = "update_card"
  case delete = "delete_card"
  case reorder = "reorder_cards"

  /// A remote access log entry's sentence (`RemoteAgentAccess`'s `tool`, `cardName` and
  /// `outcome`), or `nil` for a tool that only reads (`get_card`, `preview_card`…). It's done
  /// when the server wrote it: `ok`, or `too_large`, whose answer wasn't sent but whose write
  /// was. Any other outcome (`error`, or one added later) says what was asked.
  public static func sentence(tool: String, cardName: String?, outcome: String) -> String? {
    CardToolChange(rawValue: tool)?.sentence(
      cardName: cardName, done: outcome == "ok" || outcome == "too_large")
  }

  /// The change in a sentence, with the card's name, the person's own words: "Created card
  /// “Morning Weight”" once the log knows it went through (`done`), or else what the agent asked
  /// for, "Create card “Morning Weight”", as for a refused call, or the Mac's local log, which
  /// records a call as it comes, before the app answers. "a card" without a name.
  public func sentence(cardName: String?, done: Bool) -> String {
    let card = cardName.map { "card “\($0)”" } ?? "a card"
    return switch self {
    case .create: done ? "Created \(card)" : "Create \(card)"
    case .update: done ? "Changed \(card)" : "Change \(card)"
    case .delete: done ? "Deleted \(card)" : "Delete \(card)"
    case .reorder: done ? "Reordered cards" : "Reorder cards"
    }
  }

  /// A local access log entry's change (`AgentAccessEntry.command`, as `lil-health mcp` logs it:
  /// `create_card {"name":"Morning Weight"}`), with the name it logged, or `nil` for another
  /// command.
  public static func logged(_ command: String) -> (change: CardToolChange, cardName: String?)? {
    let parts = command.split(separator: " ", maxSplits: 1)
    guard let tool = parts.first, let change = CardToolChange(rawValue: String(tool)) else {
      return nil
    }
    let arguments = parts.count > 1 ? try? CardJSON(parsing: Data(parts[1].utf8)) : nil
    guard case .string(let name)? = arguments?["name"] else { return (change, nil) }
    return (change, name)
  }
}
