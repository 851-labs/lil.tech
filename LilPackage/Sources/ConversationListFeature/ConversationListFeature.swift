public import ComposableArchitecture
import ContactNames
public import Foundation
public import MessagesDatabase
import SQLiteData

@Reducer
public struct ConversationListFeature {
  @ObservableState
  public struct State: Equatable {
    public var contactNames: [String: String]
    /// Contact photo thumbnails by address, for one-on-one conversations.
    public var contactPhotos: [String: Data]
    public var conversations: [Conversation]
    public var filter: ConversationFilter
    public var isLoading: Bool
    public var loadFailed: Bool
    public var selection: Chat.ID?

    public init(
      contactNames: [String: String] = [:],
      contactPhotos: [String: Data] = [:],
      conversations: [Conversation] = [],
      filter: ConversationFilter = .messages,
      isLoading: Bool = false,
      loadFailed: Bool = false,
      selection: Chat.ID? = nil
    ) {
      self.contactNames = contactNames
      self.contactPhotos = contactPhotos
      self.conversations = conversations
      self.filter = filter
      self.isLoading = isLoading
      self.loadFailed = loadFailed
      self.selection = selection
    }
  }

  public enum Action {
    case contactsAccessChanged
    case contactsLoaded(names: [String: String], photos: [String: Data])
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
      case .contactsAccessChanged:
        return loadContacts(for: state.conversations)

      case .contactsLoaded(let names, let photos):
        state.contactNames = names
        state.contactPhotos = photos
        return .none

      case .conversationsLoaded(.success(let conversations)):
        state.isLoading = false
        state.loadFailed = false
        state.conversations = conversations
        if let selection = state.selection, !conversations.contains(where: { $0.id == selection }) {
          state.selection = nil
        }
        return loadContacts(for: conversations)

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
  /// Loads names for every participant, and photos for one-on-one conversations.
  private func loadContacts(for conversations: [Conversation]) -> Effect<Action> {
    let addresses = Set(conversations.flatMap(\.participants))
    let photoAddresses = Set(conversations.compactMap(\.avatarAddress))
    return .run { [contactNames] send in
      async let names = contactNames.names(addresses)
      async let photos = contactNames.photos(photoAddresses)
      await send(.contactsLoaded(names: names, photos: photos))
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
