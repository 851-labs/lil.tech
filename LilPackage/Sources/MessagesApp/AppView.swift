public import ComposableArchitecture
import ConversationListFeature
import MessageThreadFeature
import MessagesDatabase
import OnboardingFeature
public import SwiftUI

public struct AppView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      if let fullDiskAccessStore = store.scope(\.fullDiskAccess, action: \.fullDiskAccess) {
        FullDiskAccessView(store: fullDiskAccessStore)
      } else if store.hasFullDiskAccess == true {
        NavigationSplitView {
          ConversationListView(store: store.scope(\.conversationList, action: \.conversationList))
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
          if let threadStore = store.scope(\.thread, action: \.thread) {
            MessageThreadView(store: threadStore)
              .id(ThreadIdentity(chatID: threadStore.chatID, filter: threadStore.filter))
          } else {
            ContentUnavailableView(
              "No Conversation Selected",
              systemImage: "bubble.left.and.bubble.right"
            )
          }
        }
        .frame(minWidth: 720, minHeight: 480)
      } else {
        ProgressView()
          .frame(minWidth: 480, minHeight: 320)
      }
    }
    .task { await store.send(.task).finish() }
  }
}

/// Recreates the thread view when either the chat or the filter it was opened from changes.
private struct ThreadIdentity: Hashable {
  let chatID: Chat.ID
  let filter: ConversationFilter
}
