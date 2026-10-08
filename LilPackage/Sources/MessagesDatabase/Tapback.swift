/// A reaction to a message, stored as its own `message` row with an `associated_message_type` of
/// 2000–2006. Removing a reaction adds a row with 3000–3006.
public enum Tapback: Equatable, Sendable {
  case loved
  case liked
  case disliked
  case laughed
  case emphasized
  case questioned
  case emoji(String)

  /// The `associated_message_type` values of tapbacks that add a reaction.
  public static let associatedMessageTypes = 2000...2006

  public init?(associatedMessageType: Int, emoji: String?) {
    switch associatedMessageType {
    case 2000: self = .loved
    case 2001: self = .liked
    case 2002: self = .disliked
    case 2003: self = .laughed
    case 2004: self = .emphasized
    case 2005: self = .questioned
    case 2006:
      guard let emoji, !emoji.isEmpty else { return nil }
      self = .emoji(emoji)
    default: return nil
    }
  }

  /// The GUID of the message a tapback reacts to. `associated_message_guid` is either a bare GUID
  /// or one prefixed with the reacted-to part, like "p:0/<guid>" or "bp:<guid>".
  public static func reactedToGUID(fromAssociatedGUID associatedGUID: String) -> String {
    if let slash = associatedGUID.firstIndex(of: "/"), associatedGUID.hasPrefix("p:") {
      return String(associatedGUID[associatedGUID.index(after: slash)...])
    }
    if associatedGUID.hasPrefix("bp:") {
      return String(associatedGUID.dropFirst(3))
    }
    return associatedGUID
  }
}
