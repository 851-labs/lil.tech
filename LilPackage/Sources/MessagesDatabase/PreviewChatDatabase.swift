import Foundation
public import SQLiteData
public import Tagged

/// A seeded in-memory `chat.db` for Xcode previews. Tests seed their own data instead.
///
/// Dates are relative to 10:30 today, so every call produces identical rows and timestamps that
/// read naturally ("10:20 AM", "Yesterday", a weekday).
public func makePreviewChatDatabase() throws -> DatabaseQueue {
  let calendar = Calendar.current
  let now = calendar.date(bySettingHour: 10, minute: 30, second: 0, of: Date()) ?? Date()
  func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

  let database = try makeInMemoryChatDatabase()
  try database.write { db in
    try db.seed {
      PreviewChatDatabase.handles
      PreviewChatDatabase.chats
      PreviewChatDatabase.chatHandleJoins
    }
    var messageID: Int64 = 0
    for (chatID, messages) in PreviewChatDatabase.messages {
      for (handleID, text, minutes) in messages {
        messageID += 1
        let date = minutesAgo(minutes)
        try db.seed {
          Message(
            id: Message.ID(messageID),
            guid: "preview-\(messageID)",
            text: text,
            attributedBody: nil,
            handleID: handleID,
            service: "iMessage",
            date: date,
            isFromMe: handleID == 0,
            isRead: true,
            hasAttachments: false,
            itemType: 0,
            associatedMessageType: 0
          )
          ChatMessageJoin(chatID: chatID, messageID: Message.ID(messageID), messageDate: date)
        }
      }
    }
    var attachmentID: Int64 = 0
    for (chatID, handleID, files, minutes) in PreviewChatDatabase.attachmentMessages {
      messageID += 1
      let date = minutesAgo(minutes)
      try db.seed {
        Message(
          id: Message.ID(messageID),
          guid: "preview-\(messageID)",
          text: "\u{FFFC}",
          attributedBody: nil,
          handleID: handleID,
          service: "iMessage",
          date: date,
          isFromMe: handleID == 0,
          isRead: true,
          hasAttachments: true,
          itemType: 0,
          associatedMessageType: 0
        )
        ChatMessageJoin(chatID: chatID, messageID: Message.ID(messageID), messageDate: date)
      }
      for (mimeType, name) in files {
        attachmentID += 1
        try db.seed {
          Attachment(
            id: Attachment.ID(attachmentID),
            guid: "preview-attachment-\(attachmentID)",
            mimeType: mimeType,
            transferName: name
          )
          MessageAttachmentJoin(
            messageID: Message.ID(messageID), attachmentID: Attachment.ID(attachmentID))
        }
      }
    }
    for (chatID, handleID, type, reactedToID, minutes) in PreviewChatDatabase.tapbacks {
      messageID += 1
      let date = minutesAgo(minutes)
      try db.seed {
        Message(
          id: Message.ID(messageID),
          guid: "preview-\(messageID)",
          text: nil,
          attributedBody: nil,
          handleID: handleID,
          service: "iMessage",
          date: date,
          isFromMe: handleID == 0,
          isRead: true,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: type,
          associatedMessageGUID: "p:0/preview-\(reactedToID)"
        )
        ChatMessageJoin(chatID: chatID, messageID: Message.ID(messageID), messageDate: date)
      }
    }
  }
  return database
}

public enum PreviewChatDatabase {
  /// The "Weekend Plans" group chat.
  public static let groupChatID: Chat.ID = 2

  /// Names for the preview handles, for a preview `ContactIndex`.
  public static let contactNames: [(name: String, address: String)] = [
    ("Ada Lovelace", "+14155550101"),
    ("Grace Hopper", "+14155550102"),
    ("Katherine Johnson", "katherine@example.com"),
  ]

  static let handles = [
    Handle(id: 1, address: "+14155550101", service: "iMessage"),
    Handle(id: 2, address: "+14155550102", service: "iMessage"),
    Handle(id: 3, address: "katherine@example.com", service: "iMessage"),
  ]

  static let chats = [
    Chat(
      id: 1,
      guid: "iMessage;-;+14155550101",
      style: .oneOnOne,
      chatIdentifier: "+14155550101",
      serviceName: "iMessage",
      displayName: nil,
      isArchived: false
    ),
    Chat(
      id: 2,
      guid: "iMessage;+;chat000000000000000001",
      style: .group,
      chatIdentifier: "chat000000000000000001",
      serviceName: "iMessage",
      displayName: "Weekend Plans",
      isArchived: false
    ),
    Chat(
      id: 4,
      guid: "iMessage;-;+14155550102",
      style: .oneOnOne,
      chatIdentifier: "+14155550102",
      serviceName: "iMessage",
      displayName: nil,
      isArchived: false
    ),
    Chat(
      id: 3,
      guid: "iMessage;-;katherine@example.com",
      style: .oneOnOne,
      chatIdentifier: "katherine@example.com",
      serviceName: "iMessage",
      displayName: nil,
      isArchived: false
    ),
  ]

  static let chatHandleJoins = [
    ChatHandleJoin(chatID: 1, handleID: 1),
    ChatHandleJoin(chatID: 2, handleID: 1),
    ChatHandleJoin(chatID: 2, handleID: 2),
    ChatHandleJoin(chatID: 3, handleID: 3),
    ChatHandleJoin(chatID: 4, handleID: 2),
  ]

  /// Attachment-only messages as (chat, sender handle or 0 for me, files as (MIME type, name),
  /// minutes ago), seeded after `messages`.
  static let attachmentMessages: [(Chat.ID, Handle.ID, [(String, String)], Double)] = [
    (4, 2, [("image/heic", "IMG_0001.HEIC"), ("image/heic", "IMG_0002.HEIC")], 2_900)
  ]

  /// Tapbacks as (chat, sender handle or 0 for me, `associated_message_type`, reacted-to message
  /// ID, minutes ago). Message IDs count up through `messages` in order.
  static let tapbacks: [(Chat.ID, Handle.ID, Int, Int64, Double)] = [
    (1, 0, 2001, 3, 8),
    (3, 3, 2000, 10, 4_370),
  ]

  /// Messages per chat as (sender handle, or 0 for me; text; minutes ago).
  static let messages: [(Chat.ID, [(Handle.ID, String, Double)])] = [
    (
      1,
      [
        (1, "Are we still on for lunch?", 45),
        (0, "Yes! Same place as last time?", 40),
        (1, "Running 5 minutes late, save me a seat!", 10),
      ]
    ),
    (
      2,
      [
        (1, "Anyone up for a hike on Saturday?", 1_500),
        (0, "I’m in! Which trail?", 1_496),
        (2, "How about the coastal one? It’s supposed to be sunny all weekend.", 1_490),
        (1, "Perfect, let’s meet at 9", 1_485),
        (0, "See you there 🥾", 1_480),
      ]
    ),
    (
      3,
      [
        (3, "The launch window moved to Thursday.", 4_400),
        (0, "Thanks for the heads up, I’ll update the plan.", 4_380),
      ]
    ),
    (
      4,
      [
        (2, "Sending you the photos from the hike", 2_905)
      ]
    ),
  ]
}
