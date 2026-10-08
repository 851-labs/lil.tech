public import ComposableArchitecture
import ContactNames
public import MessagesDatabase
import SQLiteData

@Reducer
public struct ConversationListFeature {
  @ObservableState
  public struct State: Equatable {
    public var contactNames: [String: String]
    public var conversations: [Conversation]
    public var filter: ConversationFilter
    public var isLoading: Bool
    public var loadFailed: Bool
    public var selection: Chat.ID?

    public init(
      contactNames: [String: String] = [:],
      conversations: [Conversation] = [],
      filter: ConversationFilter = .messages,
      isLoading: Bool = false,
      loadFailed: Bool = false,
      selection: Chat.ID? = nil
    ) {
      self.contactNames = contactNames
      self.conversations = conversations
      self.filter = filter
      self.isLoading = isLoading
      self.loadFailed = loadFailed
      self.selection = selection
    }
  }

  public enum Action {
    case contactNamesLoaded([String: String])
    case contactsAccessChanged
    case conversationsLoaded(Result<[Conversation], any Error>)
    case filterChanged(ConversationFilter)
    case selectionChanged(Chat.ID?)
    case task
  }

  @Dependency(\.chatDatabase) var chatDatabase
  @Dependency(\.chatDatabaseChanges) var chatDatabaseChanges
  @Dependency(\.contactNames) var contactNames

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .contactNamesLoaded(let contactNames):
        state.contactNames = contactNames
        return .none

      case .contactsAccessChanged:
        return loadContactNames(for: state.conversations)

      case .conversationsLoaded(.success(let conversations)):
        state.isLoading = false
        state.loadFailed = false
        state.conversations = conversations
        if let selection = state.selection, !conversations.contains(where: { $0.id == selection }) {
          state.selection = nil
        }
        return loadContactNames(for: conversations)

      case .conversationsLoaded(.failure):
        state.isLoading = false
        state.loadFailed = true
        return .none

      case .filterChanged(let filter):
        guard filter != state.filter else { return .none }
        state.filter = filter
        state.conversations = []
        state.loadFailed = false
        state.selection = nil
        return .none

      case .selectionChanged(let selection):
        state.selection = selection
        return .none

      // The view restarts this task whenever the filter changes.
      case .task:
        state.isLoading = true
        return .run { [chatDatabase, chatDatabaseChanges, filter = state.filter] send in
          let changes = chatDatabaseChanges.stream()
          await send(.conversationsLoaded(await loadConversations(filter, from: chatDatabase)))
          for await _ in changes {
            await send(.conversationsLoaded(await loadConversations(filter, from: chatDatabase)))
          }
        }
      }
    }
  }
}

extension ConversationListFeature {
  private func loadContactNames(for conversations: [Conversation]) -> Effect<Action> {
    let addresses = Set(conversations.flatMap(\.participants))
    return .run { [contactNames] send in
      await send(.contactNamesLoaded(await contactNames.names(addresses)))
    }
  }
}

private func loadConversations(
  _ filter: ConversationFilter,
  from chatDatabase: ChatDatabase
) async -> Result<[Conversation], any Error> {
  await Result {
    try await chatDatabase.reader().read { db in
      try ConversationsRequest(filter: filter).fetch(db)
    }
  }
}
