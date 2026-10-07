public import ComposableArchitecture
public import MessagesDatabase
import SQLiteData

@Reducer
public struct ConversationListFeature {
  @ObservableState
  public struct State: Equatable {
    public var conversations: [Conversation]
    public var isLoading: Bool
    public var loadFailed: Bool
    public var selection: Chat.ID?

    public init(
      conversations: [Conversation] = [],
      isLoading: Bool = false,
      loadFailed: Bool = false,
      selection: Chat.ID? = nil
    ) {
      self.conversations = conversations
      self.isLoading = isLoading
      self.loadFailed = loadFailed
      self.selection = selection
    }
  }

  public enum Action {
    case conversationsLoaded(Result<[Conversation], any Error>)
    case selectionChanged(Chat.ID?)
    case task
  }

  @Dependency(\.chatDatabase) var chatDatabase

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .conversationsLoaded(.success(let conversations)):
        state.isLoading = false
        state.loadFailed = false
        state.conversations = conversations
        if let selection = state.selection, !conversations.contains(where: { $0.id == selection }) {
          state.selection = nil
        }
        return .none

      case .conversationsLoaded(.failure):
        state.isLoading = false
        state.loadFailed = true
        return .none

      case .selectionChanged(let selection):
        state.selection = selection
        return .none

      case .task:
        state.isLoading = true
        return .run { [chatDatabase] send in
          await send(
            .conversationsLoaded(
              Result {
                try await chatDatabase.reader().read { db in
                  try ConversationsRequest().fetch(db)
                }
              }
            )
          )
        }
      }
    }
  }
}
