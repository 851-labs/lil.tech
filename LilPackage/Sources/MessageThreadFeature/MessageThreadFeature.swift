public import ComposableArchitecture
public import MessagesDatabase
import SQLiteData
public import Tagged

@Reducer
public struct MessageThreadFeature {
  public static let pageSize = 100

  @ObservableState
  public struct State: Equatable, Identifiable {
    public let chatID: Chat.ID
    public var hasEarlierMessages: Bool
    public var isGroup: Bool
    public var isLoadingEarlier: Bool
    public var loadFailed: Bool
    public var messages: [ThreadMessage]
    public var title: String

    public var id: Chat.ID { chatID }

    public init(
      chatID: Chat.ID,
      title: String,
      isGroup: Bool,
      messages: [ThreadMessage] = [],
      hasEarlierMessages: Bool = true,
      isLoadingEarlier: Bool = false,
      loadFailed: Bool = false
    ) {
      self.chatID = chatID
      self.hasEarlierMessages = hasEarlierMessages
      self.isGroup = isGroup
      self.isLoadingEarlier = isLoadingEarlier
      self.loadFailed = loadFailed
      self.messages = messages
      self.title = title
    }
  }

  public enum Action {
    case earlierMessagesLoaded(Result<[ThreadMessage], any Error>)
    case latestMessagesLoaded(Result<[ThreadMessage], any Error>)
    case scrolledNearTop
    case task
  }

  @Dependency(\.chatDatabase) var chatDatabase
  @Dependency(\.chatDatabaseChanges) var chatDatabaseChanges

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .earlierMessagesLoaded(.success(let earlier)):
        state.isLoadingEarlier = false
        state.hasEarlierMessages = earlier.count == Self.pageSize
        state.messages.insert(contentsOf: earlier, at: 0)
        return .none

      case .earlierMessagesLoaded(.failure):
        state.isLoadingEarlier = false
        return .none

      case .latestMessagesLoaded(.success(let latest)):
        state.loadFailed = false
        if state.messages.isEmpty {
          state.hasEarlierMessages = latest.count == Self.pageSize
        }
        if let oldestLatest = latest.first?.cursor {
          state.messages.removeAll { !$0.cursor.isBefore(oldestLatest) }
        }
        state.messages.append(contentsOf: latest)
        return .none

      case .latestMessagesLoaded(.failure):
        state.loadFailed = true
        return .none

      case .scrolledNearTop:
        guard
          state.hasEarlierMessages,
          !state.isLoadingEarlier,
          let oldest = state.messages.first?.cursor
        else { return .none }
        state.isLoadingEarlier = true
        let request = MessageThreadRequest(
          chatID: state.chatID, before: oldest, limit: Self.pageSize)
        return .run { [chatDatabase] send in
          await send(.earlierMessagesLoaded(await fetch(request, from: chatDatabase)))
        }

      case .task:
        let request = MessageThreadRequest(chatID: state.chatID, limit: Self.pageSize)
        return .run { [chatDatabase, chatDatabaseChanges] send in
          let changes = chatDatabaseChanges.stream()
          await send(.latestMessagesLoaded(await fetch(request, from: chatDatabase)))
          for await _ in changes {
            await send(.latestMessagesLoaded(await fetch(request, from: chatDatabase)))
          }
        }
      }
    }
  }
}

private func fetch(
  _ request: MessageThreadRequest,
  from chatDatabase: ChatDatabase
) async -> Result<[ThreadMessage], any Error> {
  await Result {
    try await chatDatabase.reader().read { db in
      try request.fetch(db)
    }
  }
}

extension MessageThreadRequest.Cursor {
  func isBefore(_ other: Self) -> Bool {
    (date, id.rawValue) < (other.date, other.id.rawValue)
  }
}
