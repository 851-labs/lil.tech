import ComposableArchitecture
import ContactNames
import ConversationListFeature
import Foundation
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

@MainActor
struct ConversationListFeatureTests {
  @Test
  func loadsConversationsNewestFirst() async throws {
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
        Chat(
          id: 2,
          guid: "iMessage;+;chat000000000000000001",
          style: .group,
          chatIdentifier: "chat000000000000000001",
          serviceName: "iMessage",
          displayName: "Book Club",
          isArchived: false
        )
        ChatHandleJoin(chatID: 1, handleID: 1)
        ChatHandleJoin(chatID: 2, handleID: 1)
        message(id: 1, text: "Older", at: 100)
        message(id: 2, text: "Newer", at: 200)
        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
        ChatMessageJoin(chatID: 2, messageID: 2, messageDate: date(200))
      }
    }
    let store = TestStore(initialState: ConversationListFeature.State()) {
      ConversationListFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
      $0.contactNames = .constant(contactIndex)
    }

    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(\.conversationsLoaded.success) {
      $0.isLoading = false
      $0.conversations = [
        Conversation(
          id: 2,
          guid: "iMessage;+;chat000000000000000001",
          style: .group,
          chatIdentifier: "chat000000000000000001",
          displayName: "Book Club",
          participants: ["+15550000001"],
          latestMessage: Conversation.LatestMessage(
            date: date(200),
            text: "Newer",
            attributedBody: nil,
            isFromMe: false,
            hasAttachments: false,
            senderAddress: "+15550000001"
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
            date: date(100),
            text: "Older",
            attributedBody: nil,
            isFromMe: false,
            hasAttachments: false,
            senderAddress: "+15550000001"
          )
        ),
      ]
    }
    await store.receive(\.contactNamesLoaded) {
      $0.contactNames = ["+15550000001": "Ada Lovelace"]
    }
  }

  @Test
  func switchingFiltersReloadsThatFilter() async throws {
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
        Chat(
          id: 2,
          guid: "SMS;-;+15550000002",
          style: .oneOnOne,
          chatIdentifier: "+15550000002",
          serviceName: "SMS",
          displayName: nil,
          isArchived: false,
          isFiltered: Chat.spamFilterValue
        )
        message(id: 1, text: "Hi", at: 100)
        message(id: 2, text: "You won!", at: 200)
        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
        ChatMessageJoin(chatID: 2, messageID: 2, messageDate: date(200))
      }
    }
    let store = TestStore(
      initialState: ConversationListFeature.State(
        conversations: [conversation(id: 1, guid: "iMessage;-;+15550000001", text: "Hi", at: 100)],
        selection: 1
      )
    ) {
      ConversationListFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
      $0.contactNames = .constant(contactIndex)
    }

    await store.send(.filterChanged(.spam)) {
      $0.filter = .spam
      $0.conversations = []
      $0.selection = nil
    }
    // The view restarts its task when the filter changes.
    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(\.conversationsLoaded.success) {
      $0.isLoading = false
      $0.conversations = [
        Conversation(
          id: 2,
          guid: "SMS;-;+15550000002",
          style: .oneOnOne,
          chatIdentifier: "+15550000002",
          displayName: nil,
          participants: [],
          latestMessage: Conversation.LatestMessage(
            date: date(200),
            text: "You won!",
            attributedBody: nil,
            isFromMe: false,
            hasAttachments: false
          )
        )
      ]
    }
    await store.receive(\.contactNamesLoaded)
    await store.send(.filterChanged(.spam))
  }

  @Test
  func reloadsWhenChatDatabaseChanges() async throws {
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
        message(id: 1, text: "Hi", at: 100)
        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: date(100))
      }
    }
    let (changes, change) = AsyncStream.makeStream(of: Void.self)
    let store = TestStore(initialState: ConversationListFeature.State(selection: 1)) {
      ConversationListFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { changes }
      $0.contactNames = .constant(contactIndex)
    }

    let task = await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(\.conversationsLoaded.success) {
      $0.isLoading = false
      $0.conversations = [
        conversation(id: 1, guid: "iMessage;-;+15550000001", text: "Hi", at: 100)
      ]
    }
    await store.receive(\.contactNamesLoaded)

    try await database.write { db in
      try db.seed {
        message(id: 2, text: "New message", at: 200)
        ChatMessageJoin(chatID: 1, messageID: 2, messageDate: date(200))
      }
    }
    change.yield()
    await store.receive(\.conversationsLoaded.success) {
      $0.conversations = [
        conversation(id: 1, guid: "iMessage;-;+15550000001", text: "New message", at: 200)
      ]
    }
    await store.receive(\.contactNamesLoaded)

    change.finish()
    await task.finish()
  }

  @Test
  func loadFailure() async {
    let store = TestStore(initialState: ConversationListFeature.State()) {
      ConversationListFeature()
    } withDependencies: {
      $0.chatDatabase = ChatDatabase { throw DatabaseUnavailable() }
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
      $0.contactNames = .constant(contactIndex)
    }

    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(\.conversationsLoaded.failure) {
      $0.isLoading = false
      $0.loadFailed = true
    }
  }

  @Test
  func selection() async {
    let store = TestStore(
      initialState: ConversationListFeature.State(conversations: [conversation(id: 1)])
    ) {
      ConversationListFeature()
    }

    await store.send(.selectionChanged(1)) {
      $0.selection = 1
    }
    await store.send(.selectionChanged(nil)) {
      $0.selection = nil
    }
  }

  @Test
  func reloadClearsSelectionOfMissingConversation() async throws {
    let store = TestStore(
      initialState: ConversationListFeature.State(
        conversations: [conversation(id: 1), conversation(id: 2)],
        selection: 2
      )
    ) {
      ConversationListFeature()
    } withDependencies: {
      $0.contactNames = .constant(contactIndex)
    }

    await store.send(.conversationsLoaded(.success([conversation(id: 1)]))) {
      $0.conversations = [conversation(id: 1)]
      $0.selection = nil
    }
    await store.receive(\.contactNamesLoaded)
  }

  @Test
  func reloadsContactNamesWhenAccessChanges() async {
    var conversation = conversation(id: 1)
    conversation.participants = ["+14155550100", "friend@example.com"]
    let store = TestStore(
      initialState: ConversationListFeature.State(conversations: [conversation])
    ) {
      ConversationListFeature()
    } withDependencies: {
      $0.contactNames = .constant(contactIndex)
    }

    await store.send(.contactsAccessChanged)
    await store.receive(\.contactNamesLoaded) {
      $0.contactNames = ["+14155550100": "Grace Hopper"]
    }
  }
}

private struct DatabaseUnavailable: Error {}

private let contactIndex = ContactIndex([
  ContactIndex.Contact(name: "Ada Lovelace", phoneNumbers: ["+1 (555) 000-0001"]),
  ContactIndex.Contact(name: "Grace Hopper", phoneNumbers: ["(415) 555-0100"]),
])

private func date(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
}

private func message(id: Message.ID, text: String, at seconds: TimeInterval) -> Message {
  Message(
    id: id,
    guid: "message-\(id.rawValue)",
    text: text,
    attributedBody: nil,
    handleID: 1,
    service: "iMessage",
    date: date(seconds),
    isFromMe: false,
    isRead: true,
    hasAttachments: false,
    itemType: 0,
    associatedMessageType: 0
  )
}

private func conversation(
  id: Chat.ID,
  guid: String? = nil,
  text: String = "Hi",
  at seconds: TimeInterval = 0
) -> Conversation {
  Conversation(
    id: id,
    guid: guid ?? "iMessage;-;chat\(id.rawValue)",
    style: .oneOnOne,
    chatIdentifier: guid.map { String($0.split(separator: ";").last!) } ?? "chat\(id.rawValue)",
    displayName: nil,
    participants: [],
    latestMessage: Conversation.LatestMessage(
      date: date(seconds),
      text: text,
      attributedBody: nil,
      isFromMe: false,
      hasAttachments: false
    )
  )
}
