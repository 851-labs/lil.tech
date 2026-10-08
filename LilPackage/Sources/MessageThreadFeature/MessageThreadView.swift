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
  "Group",
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

#Preview(
  "Links",
  traits: .dependencies {
    $0.chatDatabase = .constant(try makeInMemoryChatDatabase())
  }
) {
  let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
  func message(_ id: Int64, _ text: String, isFromMe: Bool) -> ThreadMessage {
    ThreadMessage(
      id: Message.ID(900 + id),
      guid: "links-\(id)",
      date: start.addingTimeInterval(Double(id) * 60),
      text: text,
      attributedBody: nil,
      isFromMe: isFromMe,
      senderAddress: isFromMe ? nil : "+14155550101",
      hasAttachments: false
    )
  }
  return MessageThreadView(
    store: Store(
      initialState: MessageThreadFeature.State(
        chatID: 900,
        chatGUID: "iMessage;-;+14155550101",
        title: "Ada Lovelace",
        isGroup: false,
        messages: [
          message(
            1, "Your appointment is at 10:30 AM. Call (415) 555-0100 for changes.", isFromMe: false),
          message(
            2, "Details here: https://example.com/appointments/confirm?id=8f3a2c", isFromMe: false),
          message(
            3,
            "https://example.com/a/really/long/path/that/keeps/going/and/going/to/check/wrapping?with=query&params=true",
            isFromMe: false
          ),
          message(4, "Thanks! I’ll call +1 415 555 0123 if I’m late", isFromMe: true),
          message(5, "Sharing the menu: example.com/menu", isFromMe: true),
        ],
        hasEarlierMessages: false
      )
    ) {
      MessageThreadFeature()
    }
  )
  .frame(width: 520, height: 480)
}
