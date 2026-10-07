public import ComposableArchitecture
import MessagesDatabase
import SQLiteData
public import SwiftUI
import Tagged

public struct ConversationListView: View {
  @Bindable var store: StoreOf<ConversationListFeature>

  public init(store: StoreOf<ConversationListFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationSplitView {
      List(selection: $store.selection.sending(\.selectionChanged)) {
        ForEach(store.conversations) { conversation in
          ConversationRow(conversation: conversation)
            .tag(conversation.id)
        }
      }
      .navigationSplitViewColumnWidth(min: 240, ideal: 300)
      .overlay {
        if store.loadFailed {
          ContentUnavailableView(
            "Couldn’t Load Conversations",
            systemImage: "exclamationmark.bubble",
            description: Text("The Messages database couldn’t be read.")
          )
        } else if store.conversations.isEmpty, !store.isLoading {
          ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right")
        }
      }
    } detail: {
      ContentUnavailableView(
        "No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
    }
    .frame(minWidth: 720, minHeight: 480)
    .task { await store.send(.task).finish() }
  }
}

struct ConversationRow: View {
  let conversation: Conversation

  @Dependency(\.calendar) var calendar
  @Dependency(\.date.now) var now
  @Dependency(\.locale) var locale

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(
        systemName: conversation.style == .group
          ? "person.2.circle.fill"
          : "person.crop.circle.fill"
      )
      .font(.system(size: 36))
      .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(conversation.title)
            .font(.headline)
            .lineLimit(1)
          Spacer()
          Text(
            conversationTimestamp(
              conversation.latestMessage.date,
              now: now,
              calendar: calendar,
              locale: locale
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Text(conversation.previewText)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }
}

#Preview(
  traits: .dependencies {
    let database = try makeInMemoryChatDatabase()
    let now = Date()
    try database.write { db in
      try db.seed {
        Handle(id: 1, address: "+15550000001", service: "iMessage")
        Handle(id: 2, address: "+15550000002", service: "iMessage")
        Chat(
          id: 1,
          guid: "iMessage;-;+15550000001",
          style: .oneOnOne,
          chatIdentifier: "+15550000001",
          serviceName: "iMessage",
          displayName: nil,
          isArchived: false
        )
        Chat(
          id: 2,
          guid: "iMessage;+;chat000000000000000001",
          style: .group,
          chatIdentifier: "chat000000000000000001",
          serviceName: "iMessage",
          displayName: "Weekend Plans",
          isArchived: false
        )
        ChatHandleJoin(chatID: 1, handleID: 1)
        ChatHandleJoin(chatID: 2, handleID: 1)
        ChatHandleJoin(chatID: 2, handleID: 2)
        Message(
          id: 1,
          guid: "preview-1",
          text: "Running 5 minutes late, save me a seat!",
          attributedBody: nil,
          handleID: 1,
          service: "iMessage",
          date: now.addingTimeInterval(-600),
          isFromMe: false,
          isRead: false,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )
        Message(
          id: 2,
          guid: "preview-2",
          text: "Saturday works for me",
          attributedBody: nil,
          handleID: 2,
          service: "iMessage",
          date: now.addingTimeInterval(-86_400),
          isFromMe: false,
          isRead: true,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )
        ChatMessageJoin(chatID: 1, messageID: 1, messageDate: now.addingTimeInterval(-600))
        ChatMessageJoin(chatID: 2, messageID: 2, messageDate: now.addingTimeInterval(-86_400))
      }
    }
    $0.chatDatabase = .constant(database)
  }
) {
  ConversationListView(
    store: Store(initialState: ConversationListFeature.State()) {
      ConversationListFeature()
    }
  )
}
