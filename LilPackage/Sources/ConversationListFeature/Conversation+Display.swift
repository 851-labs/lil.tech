public import Foundation
public import MessagesDatabase
import UniformTypeIdentifiers

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

  /// The address whose contact photo represents a one-on-one conversation; `nil` for groups.
  public var avatarAddress: String? {
    guard style != .group else { return nil }
    return participants.first ?? chatIdentifier
  }

  /// The latest message's text, falling back to the text archived in `attributedBody`, then to a
  /// description of its attachments ("Photo", "Attachments: 2 Photos"). Tapbacks read like Messages: "Ada loved “See you there”".
  public func previewText(contactNames: [String: String] = [:]) -> String {
    if let tapback = latestMessage.tapback {
      return tapbackPreview(tapback, contactNames: contactNames)
    }
    let preview = messageBody(
      text: latestMessage.text, attributedBody: latestMessage.attributedBody)
    if preview.isEmpty, latestMessage.hasAttachments {
      return attachmentsDescription(
        latestMessage.attachments, isAudioMessage: latestMessage.isAudioMessage)
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

/// Describes attachments like Messages: "Photo", "Video", "Audio Message", "Sticker" or the file
/// name for one, and "Attachments: 2 Photos, 1 Video" for several.
func attachmentsDescription(
  _ attachments: [Conversation.AttachmentSummary],
  isAudioMessage: Bool
) -> String {
  let kinds = attachments.map { AttachmentKind($0, isAudioMessage: isAudioMessage) }
  switch kinds.count {
  case 0:
    return isAudioMessage ? "Audio Message" : "Attachment"
  case 1:
    return kinds[0] == .file
      ? attachments[0].transferName.flatMap { $0.isEmpty ? nil : $0 } ?? "File"
      : kinds[0].singular
  default:
    var counts: [(kind: AttachmentKind, count: Int)] = []
    for kind in kinds {
      if let index = counts.firstIndex(where: { $0.kind == kind }) {
        counts[index].count += 1
      } else {
        counts.append((kind, 1))
      }
    }
    let parts = counts.map { "\($0.count) \($0.count == 1 ? $0.kind.singular : $0.kind.plural)" }
    return "Attachments: \(parts.joined(separator: ", "))"
  }
}

private enum AttachmentKind {
  case audioMessage
  case file
  case photo
  case sticker
  case video

  init(_ attachment: Conversation.AttachmentSummary, isAudioMessage: Bool) {
    let type =
      attachment.mimeType.flatMap { UTType(mimeType: $0) }
      ?? attachment.uti.flatMap { UTType($0) }
    if attachment.isSticker {
      self = .sticker
    } else if let type, type.conforms(to: .image) {
      self = .photo
    } else if let type, type.conforms(to: .movie) {
      self = .video
    } else if isAudioMessage {
      self = .audioMessage
    } else {
      self = .file
    }
  }

  var singular: String {
    switch self {
    case .audioMessage: "Audio Message"
    case .file: "File"
    case .photo: "Photo"
    case .sticker: "Sticker"
    case .video: "Video"
    }
  }

  var plural: String {
    switch self {
    case .audioMessage: "Audio Messages"
    case .file: "Files"
    case .photo: "Photos"
    case .sticker: "Stickers"
    case .video: "Videos"
    }
  }
}

/// A contact's initials for a monogram avatar, e.g. "AL" for "Ada Lovelace". `nil` when the name
/// has no letters, like a phone number saved as a name.
func monogramInitials(_ name: String) -> String? {
  let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
  guard let first = words.first?.first else { return nil }
  let last = words.count > 1 ? words.last?.first : nil
  return String([first, last].compactMap(\.self)).uppercased()
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
