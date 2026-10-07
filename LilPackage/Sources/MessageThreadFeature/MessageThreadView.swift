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
    let database = try makeInMemoryChatDatabase()
    let start = Date().addingTimeInterval(-3600)
    try database.write { db in
      try db.seed {
        Handle(id: 1, address: "+15550000001", service: "iMessage")
        Handle(id: 2, address: "+15550000002", service: "iMessage")
        Chat(
          id: 1,
          guid: "iMessage;+;chat000000000000000001",
          style: .group,
          chatIdentifier: "chat000000000000000001",
          serviceName: "iMessage",
          displayName: "Weekend Plans",
          isArchived: false
        )
        for (index, (handleID, text)) in [
          (Handle.ID(1), "Anyone up for a hike on Saturday?"),
          (Handle.ID(0), "I’m in! Which trail?"),
          (Handle.ID(2), "How about the coastal one? It’s supposed to be sunny all weekend."),
          (Handle.ID(1), "Perfect, let’s meet at 9"),
          (Handle.ID(0), "See you there 🥾"),
        ].enumerated() {
          Message(
            id: Message.ID(Int64(index + 1)),
            guid: "preview-\(index)",
            text: text,
            attributedBody: nil,
            handleID: handleID,
            service: "iMessage",
            date: start.addingTimeInterval(Double(index) * 60),
            isFromMe: handleID == 0,
            isRead: true,
            hasAttachments: false,
            itemType: 0,
            associatedMessageType: 0
          )
          ChatMessageJoin(
            chatID: 1,
            messageID: Message.ID(Int64(index + 1)),
            messageDate: start.addingTimeInterval(Double(index) * 60)
          )
        }
      }
    }
    $0.chatDatabase = .constant(database)
  }
) {
  MessageThreadView(
    store: Store(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;+;chat000000000000000001",
        title: "Weekend Plans",
        isGroup: true
      )
    ) {
      MessageThreadFeature()
    }
  )
  .frame(width: 500, height: 400)
}
