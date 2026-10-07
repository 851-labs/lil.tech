public import ComposableArchitecture
import ConversationListFeature
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
        ConversationListView(store: store.scope(\.conversationList, action: \.conversationList))
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
