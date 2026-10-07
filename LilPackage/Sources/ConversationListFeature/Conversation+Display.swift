public import Foundation
public import MessagesDatabase

extension Conversation {
  /// The group name if it has one, otherwise the participants, otherwise the chat identifier.
  public var title: String {
    if let displayName, !displayName.isEmpty {
      return displayName
    }
    if !participants.isEmpty {
      return participants.formatted(.list(type: .and, width: .short))
    }
    return chatIdentifier
  }

  /// The latest message's text, falling back to the text archived in `attributedBody`, then to
  /// "Attachment".
  public var previewText: String {
    let text =
      latestMessage.text
      ?? latestMessage.attributedBody.flatMap(AttributedBody.text(from:))
      ?? ""
    let preview =
      text
      .replacing("\u{FFFC}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if preview.isEmpty, latestMessage.hasAttachments {
      return "Attachment"
    }
    return preview
  }
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
