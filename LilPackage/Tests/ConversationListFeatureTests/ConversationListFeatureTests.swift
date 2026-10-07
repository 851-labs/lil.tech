import ComposableArchitecture
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
            hasAttachments: false
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
            hasAttachments: false
          )
        ),
      ]
    }
  }

  @Test
  func loadFailure() async {
    let store = TestStore(initialState: ConversationListFeature.State()) {
      ConversationListFeature()
    } withDependencies: {
      $0.chatDatabase = ChatDatabase { throw DatabaseUnavailable() }
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
    }

    await store.send(.conversationsLoaded(.success([conversation(id: 1)]))) {
      $0.conversations = [conversation(id: 1)]
      $0.selection = nil
    }
  }
}

private struct DatabaseUnavailable: Error {}

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

private func conversation(id: Chat.ID) -> Conversation {
  Conversation(
    id: id,
    guid: "iMessage;-;chat\(id.rawValue)",
    style: .oneOnOne,
    chatIdentifier: "chat\(id.rawValue)",
    displayName: nil,
    participants: [],
    latestMessage: Conversation.LatestMessage(
      date: date(0),
      text: "Hi",
      attributedBody: nil,
      isFromMe: false,
      hasAttachments: false
    )
  )
}
