public import ComposableArchitecture
import ConversationListFeature
import MessageThreadFeature
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
              .id(threadStore.chatID)
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

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
