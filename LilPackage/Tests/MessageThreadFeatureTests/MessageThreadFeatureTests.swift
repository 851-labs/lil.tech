import ComposableArchitecture
import Foundation
import MessageSending
import MessageThreadFeature
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

@MainActor
struct MessageThreadFeatureTests {
  @Test
  func loadsLatestMessages() async throws {
    let database = try await makeDatabase(messageCount: 3)
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
    }

    await store.send(.task)
    await store.receive(\.latestMessagesLoaded.success) {
      $0.hasEarlierMessages = false
      $0.messages = [threadMessage(1), threadMessage(2), threadMessage(3)]
    }
  }

  @Test
  func mergesNewMessagesWhenChatDatabaseChanges() async throws {
    let database = try await makeDatabase(messageCount: 2)
    let (changes, change) = AsyncStream.makeStream(of: Void.self)
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { changes }
    }

    let task = await store.send(.task)
    await store.receive(\.latestMessagesLoaded.success) {
      $0.hasEarlierMessages = false
      $0.messages = [threadMessage(1), threadMessage(2)]
    }

    try await database.write { db in
      try db.seed {
        message(3)
        ChatMessageJoin(chatID: 1, messageID: 3, messageDate: date(3))
      }
    }
    change.yield()
    await store.receive(\.latestMessagesLoaded.success) {
      $0.messages = [threadMessage(1), threadMessage(2), threadMessage(3)]
    }

    change.finish()
    await task.finish()
  }

  @Test
  func loadsEarlierPagesWhenScrolledNearTop() async throws {
    let database = try await makeDatabase(messageCount: 150)
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
    }

    await store.send(.task)
    await store.receive(\.latestMessagesLoaded.success) {
      $0.messages = (51...150).map { threadMessage(Int64($0)) }
    }

    await store.send(.scrolledNearTop) {
      $0.isLoadingEarlier = true
    }
    await store.receive(\.earlierMessagesLoaded.success) {
      $0.isLoadingEarlier = false
      $0.hasEarlierMessages = false
      $0.messages = (1...150).map { threadMessage(Int64($0)) }
    }

    await store.send(.scrolledNearTop)
  }

  @Test
  func loadFailure() async {
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.chatDatabase = ChatDatabase { throw DatabaseUnavailable() }
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
    }

    await store.send(.task)
    await store.receive(\.latestMessagesLoaded.failure) {
      $0.loadFailed = true
    }
  }
}

extension MessageThreadFeatureTests {
  @Test
  func sendShowsPendingMessageUntilItAppearsInChatDatabase() async {
    let sent = LockIsolated<[(String, String)]>([])
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false,
        draft: "  Hello there \n"
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.date.now = date(10)
      $0.uuid = .incrementing
      $0.messageSender = MessageSender { text, chatGUID in
        sent.withValue { $0.append((text, chatGUID)) }
      }
    }

    await store.send(.returnKeyPressed) {
      $0.draft = ""
      $0.pendingMessages = [
        MessageThreadFeature.PendingMessage(
          id: UUID(0),
          text: "Hello there",
          sentAt: date(10)
        )
      ]
    }
    await store.receive(\.sendResponse)
    #expect(sent.value.map(\.0) == ["Hello there"])
    #expect(sent.value.map(\.1) == ["iMessage;-;+15550000001"])

    var confirmed = threadMessage(11)
    confirmed.text = "Hello there"
    confirmed.isFromMe = true
    confirmed.senderAddress = nil
    await store.send(.latestMessagesLoaded(.success([confirmed]))) {
      $0.hasEarlierMessages = false
      $0.messages = [confirmed]
      $0.pendingMessages = []
    }
  }

  @Test
  func failedSendCanBeRetried() async {
    let attempts = LockIsolated(0)
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false,
        draft: "Hello"
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.date.now = date(10)
      $0.uuid = .incrementing
      $0.messageSender = MessageSender { _, _ in
        attempts.withValue { $0 += 1 }
        if attempts.value == 1 {
          throw MessageSendError.automationDenied
        }
      }
    }

    await store.send(.returnKeyPressed) {
      $0.draft = ""
      $0.pendingMessages = [
        MessageThreadFeature.PendingMessage(id: UUID(0), text: "Hello", sentAt: date(10))
      ]
    }
    await store.receive(\.sendResponse) {
      $0.pendingMessages[0].isFailed = true
    }

    store.dependencies.date.now = date(20)
    await store.send(.failedMessageTapped(UUID(0))) {
      $0.pendingMessages[0].isFailed = false
      $0.pendingMessages[0].sentAt = date(20)
    }
    await store.receive(\.sendResponse)
    #expect(attempts.value == 2)
  }

  @Test
  func blankDraftDoesNotSend() async {
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false,
        draft: "  \n "
      )
    ) {
      MessageThreadFeature()
    }

    await store.send(.returnKeyPressed)
  }

  @Test
  func mergingLatestMessagesNeverDuplicatesIDs() async {
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false,
        messages: [threadMessage(1), threadMessage(2)]
      )
    ) {
      MessageThreadFeature()
    }

    var older = threadMessage(1)
    older.date = date(-100)
    await store.send(.latestMessagesLoaded(.success([threadMessage(2), threadMessage(3)]))) {
      $0.messages = [threadMessage(1), threadMessage(2), threadMessage(3)]
    }
    await store.send(.earlierMessagesLoaded(.success([older]))) {
      $0.hasEarlierMessages = false
    }
  }

  @Test
  func receiptShowsUnderMyLatestMessageUntilSomethingComesAfterIt() {
    var state = MessageThreadFeature.State(
      chatID: 1,
      chatGUID: "iMessage;-;+15550000001",
      title: "+15550000001",
      isGroup: false,
      messages: [threadMessage(1), threadMessage(2)]
    )
    #expect(state.receiptMessageID == 2)

    state.pendingMessages = [
      MessageThreadFeature.PendingMessage(id: UUID(0), text: "Hi", sentAt: date(3))
    ]
    #expect(state.receiptMessageID == nil)

    state.pendingMessages = []
    state.messages.append(threadMessage(3))
    #expect(state.receiptMessageID == nil)
  }

  @Test
  func readOnlyThreadsDontSend() async {
    for filter in [ConversationFilter.spam, .recentlyDeleted] {
      let store = TestStore(
        initialState: MessageThreadFeature.State(
          chatID: 1,
          chatGUID: "iMessage;-;+15550000001",
          title: "+15550000001",
          isGroup: false,
          draft: "Hello",
          filter: filter
        )
      ) {
        MessageThreadFeature()
      }
      #expect(store.state.isReadOnly)
      await store.send(.returnKeyPressed)
    }
  }

  @Test
  func recentlyDeletedThreadLoadsRecoverableMessages() async throws {
    let database = try makeInMemoryChatDatabase()
    try await database.write { db in
      try db.seed {
        Chat(
          id: 1,
          guid: "iMessage;-;+15550000001",
          style: .oneOnOne,
          chatIdentifier: "+15550000001",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )
        Message(
          id: 1,
          guid: "message-1",
          text: "Deleted",
          attributedBody: nil,
          handleID: 0,
          service: "iMessage",
          date: date(1),
          isFromMe: true,
          isRead: true,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )
        ChatRecoverableMessageJoin(chatID: 1, messageID: 1, deleteDate: date(2))
      }
    }
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false,
        filter: .recentlyDeleted
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
    }

    await store.send(.task)
    await store.receive(\.latestMessagesLoaded.success) {
      $0.messages = [
        ThreadMessage(
          id: 1,
          guid: "message-1",
          date: date(1),
          text: "Deleted",
          attributedBody: nil,
          isFromMe: true,
          senderAddress: nil,
          hasAttachments: false
        )
      ]
      $0.hasEarlierMessages = false
    }
  }

  @Test
  func textChatsAreSMSOrRCS() {
    func state(_ guid: String) -> MessageThreadFeature.State {
      MessageThreadFeature.State(chatID: 1, chatGUID: guid, title: "Ada", isGroup: false)
    }
    #expect(state("SMS;-;+15550000001").isTextChat)
    #expect(state("RCS;-;+15550000001").isTextChat)
    #expect(!state("iMessage;-;+15550000001").isTextChat)
    #expect(!state("any;-;+15550000001").isTextChat)
  }

  @Test
  func linkTappedOpensURL() async {
    let opened = LockIsolated<[URL]>([])
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.openURL = OpenURLEffect { url in
        opened.withValue { $0.append(url) }
        return true
      }
    }

    await store.send(.linkTapped(URL(string: "tel:4155550100")!))
    #expect(opened.value == [URL(string: "tel:4155550100")!])
  }

  @Test
  func draftChanged() async {
    let store = TestStore(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "+15550000001",
        isGroup: false
      )
    ) {
      MessageThreadFeature()
    }

    await store.send(.draftChanged("Hi")) {
      $0.draft = "Hi"
    }
  }
}

private struct DatabaseUnavailable: Error {}

private func makeDatabase(messageCount: Int) async throws -> DatabaseQueue {
  let database = try makeInMemoryChatDatabase()
  try await database.write { db in
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
      for index in 1...Int64(messageCount) {
        message(index)
        ChatMessageJoin(chatID: 1, messageID: Message.ID(index), messageDate: date(index))
      }
    }
  }
  return database
}

private func date(_ index: Int64) -> Date {
  Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) * 60)
}

private func message(_ index: Int64) -> Message {
  Message(
    id: Message.ID(index),
    guid: "message-\(index)",
    text: "Message \(index)",
    attributedBody: nil,
    handleID: index.isMultiple(of: 2) ? 0 : 1,
    service: "iMessage",
    date: date(index),
    isFromMe: index.isMultiple(of: 2),
    isRead: true,
    hasAttachments: false,
    itemType: 0,
    associatedMessageType: 0
  )
}

private func threadMessage(_ index: Int64) -> ThreadMessage {
  ThreadMessage(
    id: Message.ID(index),
    guid: "message-\(index)",
    date: date(index),
    text: "Message \(index)",
    attributedBody: nil,
    isFromMe: index.isMultiple(of: 2),
    senderAddress: index.isMultiple(of: 2) ? nil : "+15550000001",
    hasAttachments: false
  )
}
