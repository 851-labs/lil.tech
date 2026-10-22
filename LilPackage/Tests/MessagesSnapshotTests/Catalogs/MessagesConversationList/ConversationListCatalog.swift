#if os(macOS)
  import ComposableArchitecture
  import MessagesConversationList
  import MessagesDatabase
  import SQLiteData
  import SwiftUI
  import Testing

  // The sidebar (`ConversationListView`), from the catalog `chat.db`. Synthetic data only, and a
  // synthetic contact photo. On its own, at the sidebar's ideal width, not in a split view as the
  // previews had it: a split view's sidebar is Liquid Glass, which doesn't draw offscreen
  // (851-2957), so the list came out blank. Stores have no reducer: offscreen, the list's `.task`
  // could still run before the image, and loading would replace the seeded state (an empty list
  // shows nothing while it loads).

  extension MacSnapshotTests {
    @Test(arguments: conversationListCatalog.selectedStates)
    func conversationList(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let conversationListCatalog = StateCatalog(
    "Conversation List", width: 300, minHeight: 480,
    states: [
      CatalogState("Messages") { conversationList(filter: .messages) },
      CatalogState("Spam") { conversationList(filter: .spam) },
      CatalogState("Recently Deleted") { conversationList(filter: .recentlyDeleted) },
      CatalogState("Selection") { conversationList(selection: PreviewChatDatabase.groupChatID) },
      CatalogState("Without Contact Names") { conversationList(showsContactNames: false) },
      CatalogState("Empty") { conversationList(isEmpty: true) },
      CatalogState("Empty Spam") { conversationList(filter: .spam, isEmpty: true) },
      CatalogState("Load Failed") { conversationList(isEmpty: true, loadFailed: true) },
    ])

  /// The sidebar showing `filter`, seeded from the catalog `chat.db`.
  @MainActor
  private func conversationList(
    filter: ConversationFilter = .messages,
    selection: Chat.ID? = nil,
    showsContactNames: Bool = true,
    isEmpty: Bool = false,
    loadFailed: Bool = false
  ) -> some View {
    let conversations =
      isEmpty
      ? []
      : try! catalogChatDatabase.read { db in
        try ConversationsRequest(filter: filter).fetch(db)
      }
    return ConversationListView(
      store: Store(
        initialState: ConversationListFeature.State(
          contactNames: showsContactNames ? catalogContactNames : [:],
          contactPhotos: showsContactNames
            ? [catalogContactPhotoAddress: catalogContactPhoto] : [:],
          conversations: conversations,
          filter: filter,
          loadFailed: loadFailed,
          selection: selection
        )
      ) {
        EmptyReducer()
      }
    )
  }
#endif
