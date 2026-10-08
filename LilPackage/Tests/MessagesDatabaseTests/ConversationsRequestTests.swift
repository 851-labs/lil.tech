import CustomDump
import Foundation
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

struct ConversationsRequestTests {
  @Test
  func newestFirstWithPreviewsAndParticipants() throws {
    let database = try makeInMemoryChatDatabase()
    try database.write { db in
      try db.seed {
        Handle(id: 1, address: "+15550000001", service: "iMessage")
        Handle(id: 2, address: "+15550000002", service: "iMessage")
        Handle(id: 3, address: "friend@example.com", service: "iMessage")

        Chat(
          id: 1,
          guid: "iMessage;-;+15550000001",
          style: .oneOnOne,
          chatIdentifier: "+15550000001",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )
        Chat(
          id: 2,
          guid: "iMessage;-;friend@example.com",
          style: .oneOnOne,
          chatIdentifier: "friend@example.com",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )
        Chat(
          id: 3,
          guid: "iMessage;+;chat000000000000000001",
          style: .group,
          chatIdentifier: "chat000000000000000001",
          serviceName: "iMessage",
          displayName: "Weekend Plans",
          isArchived: false
        )
        Chat(
          id: 4,
          guid: "iMessage;-;+15550000009",
          style: .oneOnOne,
          chatIdentifier: "+15550000009",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )

        ChatHandleJoin(chatID: 1, handleID: 1)
        ChatHandleJoin(chatID: 2, handleID: 3)
        ChatHandleJoin(chatID: 3, handleID: 2)
        ChatHandleJoin(chatID: 3, handleID: 1)

        message(id: 1, text: "Hey there", handleID: 1, at: 100)
        message(id: 2, text: nil, attributedBody: Data([0x04, 0x0B]), isFromMe: true, at: 160)
        message(id: 3, text: "Saturday works for me", handleID: 2, at: 220)
        message(
          id: 4, text: "Loved “Saturday works for me”", handleID: 1, at: 300,
          associatedMessageType: 2000, associatedMessageGUID: "p:0/\(guid(3))")
        message(id: 5, text: nil, handleID: 3, at: 50, hasAttachments: true)
        message(id: 6, text: nil, handleID: 1, at: 400, itemType: 1)

        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
        ChatMessageJoin(chatID: 1, messageID: 2, messageDate: date(160))
        ChatMessageJoin(chatID: 3, messageID: 3, messageDate: date(220))
        ChatMessageJoin(chatID: 3, messageID: 4, messageDate: date(300))
        ChatMessageJoin(chatID: 2, messageID: 5, messageDate: date(50))
        ChatMessageJoin(chatID: 3, messageID: 6, messageDate: date(400))
      }
    }

    let conversations = try database.read { db in try ConversationsRequest().fetch(db) }

    expectNoDifference(
      conversations,
      [
        Conversation(
          id: 3,
          guid: "iMessage;+;chat000000000000000001",
          style: .group,
          chatIdentifier: "chat000000000000000001",
          displayName: "Weekend Plans",
          participants: ["+15550000001", "+15550000002"],
          latestMessage: Conversation.LatestMessage(
            date: date(300),
            text: "Loved “Saturday works for me”",
            attributedBody: nil,
            isFromMe: false,
            hasAttachments: false,
            senderAddress: "+15550000001",
            tapback: .loved,
            reactedTo: Conversation.ReactedMessage(
              body: "Saturday works for me", hasAttachments: false)
          )
        ),
        Conversation(
          id: 1,
          guid: "iMessage;-;+15550000001",
          style: .oneOnOne,
          chatIdentifier: "+15550000001",
          displayName: nil,
          participants: ["+15550000001"],
          latestMessage: Conversation.LatestMessage(
            date: date(160),
            text: nil,
            attributedBody: Data([0x04, 0x0B]),
            isFromMe: true,
            hasAttachments: false
          )
        ),
        Conversation(
          id: 2,
          guid: "iMessage;-;friend@example.com",
          style: .oneOnOne,
          chatIdentifier: "friend@example.com",
          displayName: nil,
          participants: ["friend@example.com"],
          latestMessage: Conversation.LatestMessage(
            date: date(50),
            text: nil,
            attributedBody: nil,
            isFromMe: false,
            hasAttachments: true,
            senderAddress: "friend@example.com"
          )
        ),
      ]
    )
  }

  @Test
  func tapbacksWithMissingOriginalsAndIgnoredRemovals() throws {
    let database = try makeInMemoryChatDatabase()
    try database.write { db in
      try db.seed {
        Handle(id: 1, address: "+15550000001", service: "iMessage")
        Chat(
          id: 1,
          guid: "iMessage;-;+15550000001",
          style: .oneOnOne,
          chatIdentifier: "+15550000001",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )
        Chat(
          id: 2,
          guid: "iMessage;-;+15550000002",
          style: .oneOnOne,
          chatIdentifier: "+15550000002",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )
        message(id: 1, text: "Hello", handleID: 1, at: 100)
        message(
          id: 2, text: "Reacted 🔥 to a message", isFromMe: true, at: 200,
          associatedMessageType: 2006, associatedMessageGUID: "p:0/deleted-message",
          associatedMessageEmoji: "🔥")
        message(id: 3, text: "Hi", handleID: 1, at: 300)
        message(
          id: 4, text: "Removed a heart from “Hi”", isFromMe: true, at: 400,
          associatedMessageType: 3000, associatedMessageGUID: "p:0/\(guid(3))")
        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
        ChatMessageJoin(chatID: 1, messageID: 2, messageDate: date(200))
        ChatMessageJoin(chatID: 2, messageID: 3, messageDate: date(300))
        ChatMessageJoin(chatID: 2, messageID: 4, messageDate: date(400))
      }
    }

    let conversations = try database.read { db in try ConversationsRequest().fetch(db) }

    #expect(conversations.map(\.id) == [2, 1])
    #expect(conversations[0].latestMessage.tapback == nil)
    #expect(conversations[0].latestMessage.text == "Hi")
    #expect(conversations[1].latestMessage.tapback == .emoji("🔥"))
    #expect(conversations[1].latestMessage.isFromMe)
    #expect(conversations[1].latestMessage.reactedTo == nil)
  }

  @Test
  func latestMessageAttachmentsSkipHiddenOnes() throws {
    let database = try makeInMemoryChatDatabase()
    try database.write { db in
      try db.seed {
        Handle(id: 1, address: "+15550000001", service: "iMessage")
        Chat(
          id: 1,
          guid: "iMessage;-;+15550000001",
          style: .oneOnOne,
          chatIdentifier: "+15550000001",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )
        message(id: 1, text: nil, handleID: 1, at: 100, hasAttachments: true)
        Attachment(id: 1, guid: "a1", mimeType: "image/heic", transferName: "IMG_0001.HEIC")
        Attachment(id: 2, guid: "a2", mimeType: nil, transferName: nil, isHidden: true)
        Attachment(id: 3, guid: "a3", mimeType: "video/quicktime", transferName: "IMG_0002.MOV")
        MessageAttachmentJoin(messageID: 1, attachmentID: 1)
        MessageAttachmentJoin(messageID: 1, attachmentID: 2)
        MessageAttachmentJoin(messageID: 1, attachmentID: 3)
        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
      }
    }

    let conversations = try database.read { db in try ConversationsRequest().fetch(db) }

    #expect(
      conversations.first?.latestMessage.attachments == [
        Conversation.AttachmentSummary(
          mimeType: "image/heic", uti: nil, transferName: "IMG_0001.HEIC"),
        Conversation.AttachmentSummary(
          mimeType: "video/quicktime", uti: nil, transferName: "IMG_0002.MOV"),
      ]
    )
  }

  @Test
  func filtersSeparateSpamAndRecentlyDeleted() throws {
    let database = try makeInMemoryChatDatabase()
    try database.write { db in
      try db.seed {
        Handle(id: 1, address: "+15550000001", service: "iMessage")
        for (id, isFiltered) in [(1, 0), (2, 1), (3, Chat.spamFilterValue), (4, 0)] {
          Chat(
            id: Chat.ID(Int64(id)),
            guid: "iMessage;-;+1555000000\(id)",
            style: .oneOnOne,
            chatIdentifier: "+1555000000\(id)",
            serviceName: "iMessage",
            displayName: nil,
            isArchived: false,
            isFiltered: isFiltered
          )
        }
        message(id: 1, text: "Known sender", handleID: 1, at: 100)
        message(id: 2, text: "Unknown sender", handleID: 1, at: 200)
        message(id: 3, text: "Spam", handleID: 1, at: 300)
        message(id: 4, text: "Kept", handleID: 1, at: 400)
        message(id: 5, text: "Deleted", handleID: 1, at: 500)
        message(id: 6, text: "Deleted conversation", handleID: 1, at: 50)
        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
        ChatMessageJoin(chatID: 2, messageID: 2, messageDate: date(200))
        ChatMessageJoin(chatID: 3, messageID: 3, messageDate: date(300))
        ChatMessageJoin(chatID: 4, messageID: 4, messageDate: date(400))
        ChatRecoverableMessageJoin(chatID: 4, messageID: 5, deleteDate: date(600))
        ChatRecoverableMessageJoin(chatID: 1, messageID: 6, deleteDate: date(600))
      }
    }

    func fetch(_ filter: ConversationFilter) throws -> [(Chat.ID, String?)] {
      try database.read { db in
        try ConversationsRequest(filter: filter).fetch(db).map { ($0.id, $0.latestMessage.text) }
      }
    }
    #expect(try fetch(.messages).map(\.0) == [4, 2, 1])
    #expect(try fetch(.messages).map(\.1) == ["Kept", "Unknown sender", "Known sender"])
    #expect(try fetch(.spam).map(\.0) == [3])
    #expect(try fetch(.recentlyDeleted).map(\.0) == [4, 1])
    #expect(try fetch(.recentlyDeleted).map(\.1) == ["Deleted", "Deleted conversation"])
  }

  @Test
  func reactedToGUIDs() {
    #expect(Tapback.reactedToGUID(fromAssociatedGUID: "p:0/ABC-123") == "ABC-123")
    #expect(Tapback.reactedToGUID(fromAssociatedGUID: "p:12/ABC-123") == "ABC-123")
    #expect(Tapback.reactedToGUID(fromAssociatedGUID: "bp:ABC-123") == "ABC-123")
    #expect(Tapback.reactedToGUID(fromAssociatedGUID: "ABC-123") == "ABC-123")
  }

  @Test
  func tapbackTypes() {
    #expect(Tapback(associatedMessageType: 2000, emoji: nil) == .loved)
    #expect(Tapback(associatedMessageType: 2001, emoji: nil) == .liked)
    #expect(Tapback(associatedMessageType: 2002, emoji: nil) == .disliked)
    #expect(Tapback(associatedMessageType: 2003, emoji: nil) == .laughed)
    #expect(Tapback(associatedMessageType: 2004, emoji: nil) == .emphasized)
    #expect(Tapback(associatedMessageType: 2005, emoji: nil) == .questioned)
    #expect(Tapback(associatedMessageType: 2006, emoji: "🎉") == .emoji("🎉"))
    #expect(Tapback(associatedMessageType: 2006, emoji: nil) == nil)
    #expect(Tapback(associatedMessageType: 0, emoji: nil) == nil)
    #expect(Tapback(associatedMessageType: 3000, emoji: nil) == nil)
  }

  @Test
  func emptyDatabase() throws {
    let database = try makeInMemoryChatDatabase()
    let conversations = try database.read { db in try ConversationsRequest().fetch(db) }
    #expect(conversations.isEmpty)
  }
}

private func date(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
}

private func message(
  id: Message.ID,
  text: String?,
  attributedBody: Data? = nil,
  handleID: Handle.ID = 0,
  isFromMe: Bool = false,
  at seconds: TimeInterval,
  hasAttachments: Bool = false,
  itemType: Int = 0,
  associatedMessageType: Int = 0,
  associatedMessageGUID: String? = nil,
  associatedMessageEmoji: String? = nil
) -> Message {
  Message(
    id: id,
    guid: guid(id),
    text: text,
    attributedBody: attributedBody,
    handleID: handleID,
    service: "iMessage",
    date: date(seconds),
    isFromMe: isFromMe,
    isRead: true,
    hasAttachments: hasAttachments,
    itemType: itemType,
    associatedMessageType: associatedMessageType,
    associatedMessageGUID: associatedMessageGUID,
    associatedMessageEmoji: associatedMessageEmoji
  )
}

private func guid(_ id: Message.ID) -> String {
  "00000000-0000-0000-0000-\(String(format: "%012d", id.rawValue))"
}
