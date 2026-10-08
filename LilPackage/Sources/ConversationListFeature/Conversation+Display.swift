public import Foundation
public import MessagesDatabase

extension Conversation {
  /// The group name if it has one, otherwise the participants (by contact name when known, else as
  /// a formatted phone number or email), otherwise the chat identifier.
  public func title(contactNames: [String: String] = [:]) -> String {
    if let displayName, !displayName.isEmpty {
      return displayName
    }
    if !participants.isEmpty {
      return
        participants
        .map { contactNames[$0] ?? formattedHandle($0) }
        .formatted(.list(type: .and, width: .short))
    }
    return contactNames[chatIdentifier] ?? formattedHandle(chatIdentifier)
  }

  /// The latest message's text, falling back to the text archived in `attributedBody`, then to
  /// "Attachment". Tapbacks read like Messages: "Ada loved “See you there”".
  public func previewText(contactNames: [String: String] = [:]) -> String {
    if let tapback = latestMessage.tapback {
      return tapbackPreview(tapback, contactNames: contactNames)
    }
    let preview = messageBody(
      text: latestMessage.text, attributedBody: latestMessage.attributedBody)
    if preview.isEmpty, latestMessage.hasAttachments {
      return "Attachment"
    }
    return preview
  }

  private func tapbackPreview(_ tapback: Tapback, contactNames: [String: String]) -> String {
    let sender: String
    if latestMessage.isFromMe {
      sender = "You"
    } else {
      let address = latestMessage.senderAddress ?? chatIdentifier
      sender = contactNames[address].map(firstName) ?? formattedHandle(address)
    }

    let verb =
      switch tapback {
      case .loved: "loved"
      case .liked: "liked"
      case .disliked: "disliked"
      case .laughed: "laughed at"
      case .emphasized: "emphasized"
      case .questioned: "questioned"
      case .emoji(let emoji): "reacted \(emoji) to"
      }

    let target: String
    if let reactedTo = latestMessage.reactedTo, !reactedTo.body.isEmpty {
      target = "“\(truncatedQuote(reactedTo.body))”"
    } else if latestMessage.reactedTo?.hasAttachments == true {
      target = "an attachment"
    } else {
      target = "a message"
    }
    return "\(sender) \(verb) \(target)"
  }
}

/// The first word of a contact's name, like Messages uses in tapback previews.
private func firstName(_ name: String) -> String {
  name.split(separator: " ").first.map(String.init) ?? name
}

/// Messages quotes at most 50 characters of the reacted-to message.
private func truncatedQuote(_ text: String) -> String {
  let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
  guard singleLine.count > 50 else { return singleLine }
  return singleLine.prefix(50).trimmingCharacters(in: .whitespaces) + "…"
}

/// Formats a message date like Messages does in its sidebar: the time for today, "Yesterday", the
/// weekday within the last week, and a short date otherwise.
public func conversationTimestamp(
  _ date: Date,
  now: Date,
  calendar: Calendar,
  locale: Locale
) -> String {
  let startOfToday = calendar.startOfDay(for: now)
  let startOfDate = calendar.startOfDay(for: date)
  let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
  var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
  switch daysAgo {
  case ...0:
    style = style.hour().minute()
  case 1:
    return String(localized: "Yesterday")
  case 2..<7:
    style = style.weekday(.wide)
  default:
    style = style.year(.twoDigits).month(.defaultDigits).day(.defaultDigits)
  }
  return date.formatted(style)
}
