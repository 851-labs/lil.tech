#if os(macOS)
  import ComposableArchitecture
  import MessagesConversationList
  import MessagesDatabase
  import MessagesMacApp
  import MessagesOnboarding
  import MessagesThread
  import SQLiteData
  import SwiftUI
  import Testing

  // The window (`AppView`) in each of the app's states, from the catalog `chat.db`. Synthetic
  // data only. Stores have no reducer, so a `.task` that runs before the image can't replace a
  // state: the catalog database always opens, so the access check would show the conversations
  // (851-2705). The sidebar is Liquid Glass, which doesn't draw offscreen (851-2957):
  // `ConversationListCatalog` shows it.

  extension MacSnapshotTests {
    @Test(arguments: windowCatalog.selectedStates)
    func window(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let windowCatalog = StateCatalog(
    "Window", width: 720, minHeight: 480,
    states: [
      CatalogState("Checking Access", width: 480, minHeight: 320) {
        AppView(store: Store(initialState: AppFeature.State()) { EmptyReducer() })
      },
      CatalogState("Needs Full Disk Access", width: 480, minHeight: 320) {
        var state = AppFeature.State()
        state.hasFullDiskAccess = false
        state.fullDiskAccess = FullDiskAccessFeature.State()
        return AppView(store: Store(initialState: state) { EmptyReducer() })
      },
      CatalogState("Nothing Selected") {
        AppView(store: Store(initialState: loadedState(selection: nil)) { EmptyReducer() })
      },
      CatalogState("Thread Open") {
        AppView(
          store: Store(initialState: loadedState(selection: PreviewChatDatabase.groupChatID)) {
            EmptyReducer()
          })
      },
    ])

  /// The app with Full Disk Access, the catalog conversations loaded, and `selection` open.
  private func loadedState(selection: Chat.ID?) -> AppFeature.State {
    let conversations = try! catalogChatDatabase.read { db in
      try ConversationsRequest().fetch(db)
    }
    var state = AppFeature.State()
    state.hasFullDiskAccess = true
    state.conversationList = ConversationListFeature.State(
      contactNames: catalogContactNames,
      conversations: conversations,
      selection: selection
    )
    if let selection, let conversation = conversations.first(where: { $0.id == selection }) {
      let messages = try! catalogChatDatabase.read { db in
        try MessageThreadRequest(chatID: selection).fetch(db)
      }
      state.thread = MessageThreadFeature.State(
        chatID: selection,
        chatGUID: conversation.guid,
        title: conversation.title(contactNames: catalogContactNames),
        isGroup: conversation.style == .group,
        messages: messages,
        senderNames: catalogContactNames,
        hasEarlierMessages: false
      )
    }
    return state
  }
#endif
