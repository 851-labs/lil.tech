import CustomDump
import Foundation
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

struct MessageThreadRequestTests {
  @Test
  func latestPageOldestFirst() throws {
    let database = try makeSeededDatabase()

    let page = try database.read { db in
      try MessageThreadRequest(chatID: 1, limit: 3).fetch(db)
    }

    expectNoDifference(
      page,
      [
        threadMessage(id: 3, text: "Same time, lower ID", isFromMe: true, at: 300),
        threadMessage(id: 4, text: "Same time, higher ID", sender: "+15550000001", at: 300),
        threadMessage(id: 5, text: "Latest", sender: "+15550000001", at: 400),
      ]
    )
  }

  @Test
  func readsDeliveryReadEditedAndErrorColumns() throws {
    let database = try makeInMemoryChatDatabase()
    try database.write { db in
      var delivered = message(id: 1, text: "Delivered", isFromMe: true, at: 100)
      delivered.isDelivered = true
      var read = message(id: 2, text: "Read", isFromMe: true, at: 200)
      read.isDelivered = true
      read.dateRead = date(250)
      var edited = message(id: 3, text: "Edited", handleID: 1, at: 300)
      edited.dateEdited = date(350)
      var failed = message(id: 4, text: "Failed", isFromMe: true, at: 400)
      failed.error = 22
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
        delivered
        read
        edited
        failed
        for id in 1...4 {
          ChatMessageJoin(
            chatID: 1, messageID: Message.ID(Int64(id)), messageDate: date(Double(id) * 100))
        }
      }
    }

    let page = try database.read { db in
      try MessageThreadRequest(chatID: 1).fetch(db)
    }

    #expect(page.map(\.isDelivered) == [true, true, false, false])
    #expect(page.map(\.dateRead) == [nil, date(250), nil, nil])
    #expect(page.map(\.dateEdited) == [nil, nil, date(350), nil])
    #expect(page.map(\.hasError) == [false, false, false, true])
  }

  @Test
  func recentlyDeletedReadsRecoverableMessagesWithPaging() throws {
    let database = try makeSeededDatabase()
    try database.write { db in
      try db.seed {
        message(id: 20, text: "Deleted first", handleID: 1, at: 1_000)
        message(id: 21, text: "Deleted second", isFromMe: true, at: 1_100)
        message(id: 22, text: "Deleted third", handleID: 1, at: 1_200)
        message(id: 23, text: "Deleted elsewhere", handleID: 1, at: 1_300)
        ChatRecoverableMessageJoin(chatID: 1, messageID: 20, deleteDate: date(5_000))
        ChatRecoverableMessageJoin(chatID: 1, messageID: 21, deleteDate: date(5_000))
        ChatRecoverableMessageJoin(chatID: 1, messageID: 22, deleteDate: date(5_000))
        ChatRecoverableMessageJoin(chatID: 2, messageID: 23, deleteDate: date(5_000))
      }
    }

    let latest = try database.read { db in
      try MessageThreadRequest(chatID: 1, limit: 2, recentlyDeleted: true).fetch(db)
    }
    #expect(latest.map(\.text) == ["Deleted second", "Deleted third"])

    let earlier = try database.read { db in
      try MessageThreadRequest(
        chatID: 1, before: latest[0].cursor, limit: 2, recentlyDeleted: true
      ).fetch(db)
    }
    #expect(earlier.map(\.text) == ["Deleted first"])
  }

  @Test
  func pageBeforeCursor() throws {
    let database = try makeSeededDatabase()

    let latest = try database.read { db in
      try MessageThreadRequest(chatID: 1, limit: 2).fetch(db)
    }
    let earlier = try database.read { db in
      try MessageThreadRequest(chatID: 1, before: latest[0].cursor, limit: 2).fetch(db)
    }
    let earliest = try database.read { db in
      try MessageThreadRequest(chatID: 1, before: earlier[0].cursor, limit: 2).fetch(db)
    }

    #expect(latest.map(\.id) == [4, 5])
    #expect(earlier.map(\.id) == [2, 3])
    #expect(earliest.map(\.id) == [1])
  }

  @Test
  func excludesTapbacksGroupEventsAndOtherChats() throws {
    let database = try makeSeededDatabase()

    let page = try database.read { db in
      try MessageThreadRequest(chatID: 1).fetch(db)
    }

    #expect(page.map(\.id) == [1, 2, 3, 4, 5])
  }

  @Test
  func bodyFallsBackToAttributedBody() {
    let message = ThreadMessage(
      id: 1,
      guid: "message-1",
      date: date(0),
      text: nil,
      attributedBody: Data(helloArchive),
      isFromMe: false,
      senderAddress: nil,
      hasAttachments: false
    )
    #expect(message.body == "Hello")
  }

  @Test
  func textMessagesAreSMSOrRCS() {
    func message(service: String?) -> ThreadMessage {
      ThreadMessage(
        id: 1,
        guid: "message-1",
        date: date(0),
        text: "Hi",
        attributedBody: nil,
        isFromMe: true,
        senderAddress: nil,
        hasAttachments: false,
        service: service
      )
    }
    #expect(message(service: "SMS").isTextMessage)
    #expect(message(service: "RCS").isTextMessage)
    #expect(!message(service: "iMessage").isTextMessage)
    #expect(!message(service: nil).isTextMessage)
  }

  @Test
  func bodyDropsAttachmentPlaceholders() {
    let message = ThreadMessage(
      id: 1,
      guid: "message-1",
      date: date(0),
      text: "\u{FFFC}Look at this",
      attributedBody: nil,
      isFromMe: false,
      senderAddress: nil,
      hasAttachments: true
    )
    #expect(message.body == "Look at this")
  }
}

private func makeSeededDatabase() throws -> DatabaseQueue {
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
      ChatHandleJoin(chatID: 1, handleID: 1)

      message(id: 1, text: "First", handleID: 1, at: 100)
      message(id: 2, text: "Second", isFromMe: true, at: 200)
      message(id: 3, text: "Same time, lower ID", isFromMe: true, at: 300)
      message(id: 4, text: "Same time, higher ID", handleID: 1, at: 300)
      message(id: 5, text: "Latest", handleID: 1, at: 400)
      message(id: 6, text: "Loved “Latest”", isFromMe: true, at: 500, associatedMessageType: 2000)
      message(id: 7, text: nil, handleID: 1, at: 600, itemType: 1)
      message(id: 8, text: "Another chat", handleID: 1, at: 700)

      ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
      ChatMessageJoin(chatID: 1, messageID: 2, messageDate: date(200))
      ChatMessageJoin(chatID: 1, messageID: 3, messageDate: date(300))
      ChatMessageJoin(chatID: 1, messageID: 4, messageDate: date(300))
      ChatMessageJoin(chatID: 1, messageID: 5, messageDate: date(400))
      ChatMessageJoin(chatID: 1, messageID: 6, messageDate: date(500))
      ChatMessageJoin(chatID: 1, messageID: 7, messageDate: date(600))
      ChatMessageJoin(chatID: 2, messageID: 8, messageDate: date(700))
    }
  }
  return database
}

private func date(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
}

private func message(
  id: Message.ID,
  text: String?,
  handleID: Handle.ID = 0,
  isFromMe: Bool = false,
  at seconds: TimeInterval,
  itemType: Int = 0,
  associatedMessageType: Int = 0
) -> Message {
  Message(
    id: id,
    guid: "message-\(id.rawValue)",
    text: text,
    attributedBody: nil,
    handleID: handleID,
    service: "iMessage",
    date: date(seconds),
    isFromMe: isFromMe,
    isRead: true,
    hasAttachments: false,
    itemType: itemType,
    associatedMessageType: associatedMessageType
  )
}

private func threadMessage(
  id: Message.ID,
  text: String,
  sender: String? = nil,
  isFromMe: Bool = false,
  at seconds: TimeInterval
) -> ThreadMessage {
  ThreadMessage(
    id: id,
    guid: "message-\(id.rawValue)",
    date: date(seconds),
    text: text,
    attributedBody: nil,
    isFromMe: isFromMe,
    senderAddress: sender,
    hasAttachments: false
  )
}

/// `NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Hello"))`
private let helloArchive: [UInt8] = [
  0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64, 0x81, 0xE8, 0x03,
  0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12, 0x4E, 0x53, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75,
  0x74, 0x65, 0x64, 0x53, 0x74, 0x72, 0x69, 0x6E, 0x67, 0x00, 0x84, 0x84, 0x08, 0x4E, 0x53, 0x4F,
  0x62, 0x6A, 0x65, 0x63, 0x74, 0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08, 0x4E, 0x53, 0x53, 0x74,
  0x72, 0x69, 0x6E, 0x67, 0x01, 0x94, 0x84, 0x01, 0x2B, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x86,
  0x84, 0x02, 0x69, 0x49, 0x01, 0x05, 0x92, 0x84, 0x84, 0x84, 0x0C, 0x4E, 0x53, 0x44, 0x69, 0x63,
  0x74, 0x69, 0x6F, 0x6E, 0x61, 0x72, 0x79, 0x00, 0x94, 0x84, 0x01, 0x69, 0x00, 0x86, 0x86,
]
