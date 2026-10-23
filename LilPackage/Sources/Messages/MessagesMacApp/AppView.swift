public import ComposableArchitecture
import LilUI
import MessagesConversationList
import MessagesDatabase
import MessagesOnboarding
import MessagesThread
public import SwiftUI

public struct AppView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      if isChecking {
        // Its space, under the spinner `delayedProgress` shows (851-3086).
        Color.clear
          .frame(minWidth: 480, minHeight: 320)
      } else if let fullDiskAccessStore = store.scope(\.fullDiskAccess, action: \.fullDiskAccess) {
        FullDiskAccessView(store: fullDiskAccessStore)
      } else {
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
      }
    }
    .delayedProgress(isLoading: isChecking)
    .task { await store.send(.task).finish() }
  }

  /// Whether Full Disk Access isn't known yet: no onboarding to show, and access not granted.
  private var isChecking: Bool {
    store.fullDiskAccess == nil && store.hasFullDiskAccess != true
  }
}

/// Recreates the thread view when either the chat or the filter it was opened from changes.
private struct ThreadIdentity: Hashable {
  let chatID: Chat.ID
  let filter: ConversationFilter
}
