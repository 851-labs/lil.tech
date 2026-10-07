public import ComposableArchitecture
import MessagesDatabase
import SQLiteData
public import SwiftUI
import Tagged

public struct MessageThreadView: View {
  let store: StoreOf<MessageThreadFeature>

  public init(store: StoreOf<MessageThreadFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: 0) {
      MessageList(store: store)
      Divider()
      ComposerView(store: store)
        .frame(height: 64)
        .overlay(alignment: .topLeading) {
          if store.draft.isEmpty {
            Text("iMessage")
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 13)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
        }
    }
    .overlay {
      if store.loadFailed {
        ContentUnavailableView(
          "Couldn’t Load Messages",
          systemImage: "exclamationmark.bubble",
          description: Text("The Messages database couldn’t be read.")
        )
      }
    }
    .navigationTitle(store.title)
    .task { await store.send(.task).finish() }
  }
}

private struct MessageList: NSViewControllerRepresentable {
  let store: StoreOf<MessageThreadFeature>

  func makeNSViewController(context: Context) -> MessageThreadViewController {
    MessageThreadViewController(store: store)
  }

  func updateNSViewController(_ viewController: MessageThreadViewController, context: Context) {}
}

#Preview(
  traits: .dependencies {
    $0.chatDatabase = .constant(try makePreviewChatDatabase())
  }
) {
  let messages = try! makePreviewChatDatabase().read { db in
    try MessageThreadRequest(chatID: PreviewChatDatabase.groupChatID).fetch(db)
  }
  MessageThreadView(
    store: Store(
      initialState: MessageThreadFeature.State(
        chatID: PreviewChatDatabase.groupChatID,
        chatGUID: "iMessage;+;chat000000000000000001",
        title: "Weekend Plans",
        isGroup: true,
        messages: messages,
        senderNames: Dictionary(
          uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) }
        ),
        hasEarlierMessages: false
      )
    ) {
      MessageThreadFeature()
    }
  )
  .frame(width: 500, height: 420)
}
