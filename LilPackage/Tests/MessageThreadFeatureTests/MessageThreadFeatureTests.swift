import ComposableArchitecture
import Foundation
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
      initialState: MessageThreadFeature.State(chatID: 1, title: "+15550000001", isGroup: false)
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
      initialState: MessageThreadFeature.State(chatID: 1, title: "+15550000001", isGroup: false)
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
      initialState: MessageThreadFeature.State(chatID: 1, title: "+15550000001", isGroup: false)
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
      initialState: MessageThreadFeature.State(chatID: 1, title: "+15550000001", isGroup: false)
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
