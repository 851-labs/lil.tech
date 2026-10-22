import Foundation
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

struct InMemoryChatDatabaseTests {
  @Test
  func seedsAndReadsBackEveryTable() throws {
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

        ChatHandleJoin(chatID: 1, handleID: 1)
        ChatHandleJoin(chatID: 2, handleID: 3)
        ChatHandleJoin(chatID: 3, handleID: 1)
        ChatHandleJoin(chatID: 3, handleID: 2)

        Message(
          id: 1,
          guid: "00000000-0000-0000-0000-000000000001",
          text: "Hey there",
          attributedBody: nil,
          handleID: 1,
          service: "iMessage",
          date: Date(timeIntervalSinceReferenceDate: 800_000_000),
          isFromMe: false,
          isRead: true,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )
        Message(
          id: 2,
          guid: "00000000-0000-0000-0000-000000000002",
          text: nil,
          attributedBody: Data([0x04, 0x0B]),
          handleID: 0,
          service: "iMessage",
          date: Date(timeIntervalSinceReferenceDate: 800_000_060),
          isFromMe: true,
          isRead: true,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )
        Message(
          id: 3,
          guid: "00000000-0000-0000-0000-000000000003",
          text: "Saturday works for me",
          attributedBody: nil,
          handleID: 2,
          service: "iMessage",
          date: Date(timeIntervalSinceReferenceDate: 800_000_120),
          isFromMe: false,
          isRead: false,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )

        ChatMessageJoin(
          chatID: 1,
          messageID: 1,
          messageDate: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        ChatMessageJoin(
          chatID: 1,
          messageID: 2,
          messageDate: Date(timeIntervalSinceReferenceDate: 800_000_060)
        )
        ChatMessageJoin(
          chatID: 3,
          messageID: 3,
          messageDate: Date(timeIntervalSinceReferenceDate: 800_000_120)
        )
      }
    }

    try database.read { db in
      #expect(try Chat.fetchCount(db) == 3)
      #expect(try Handle.fetchCount(db) == 3)
      #expect(try Message.fetchCount(db) == 3)
      #expect(try ChatHandleJoin.fetchCount(db) == 4)
      #expect(try ChatMessageJoin.fetchCount(db) == 3)

      let groupChat = try #require(try Chat.where { $0.style.eq(Chat.Style.group) }.fetchOne(db))
      #expect(groupChat.displayName == "Weekend Plans")

      let bodyOnlyMessage = try #require(try Message.find(Message.ID(2)).fetchOne(db))
      #expect(bodyOnlyMessage.text == nil)
      #expect(bodyOnlyMessage.attributedBody == Data([0x04, 0x0B]))
      #expect(bodyOnlyMessage.isFromMe)
      #expect(bodyOnlyMessage.date == Date(timeIntervalSinceReferenceDate: 800_000_060))
    }
  }

  @Test
  func storesDatesAsNanosecondsLikeChatDB() throws {
    let database = try makeInMemoryChatDatabase()
    try database.write { db in
      try db.seed {
        Message(
          id: 1,
          guid: "00000000-0000-0000-0000-000000000001",
          text: "Hi",
          attributedBody: nil,
          handleID: 0,
          service: "iMessage",
          date: Date(timeIntervalSinceReferenceDate: 800_000_000),
          isFromMe: true,
          isRead: true,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )
      }
    }

    let rawDate = try database.read { db in
      try Int64.fetchOne(db, sql: "SELECT date FROM message WHERE ROWID = 1")
    }
    #expect(rawDate == 800_000_000_000_000_000)
  }
}
