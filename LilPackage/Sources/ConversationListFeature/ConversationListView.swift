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
    List(selection: $store.selection.sending(\.selectionChanged)) {
      ForEach(store.conversations) { conversation in
        ConversationRow(conversation: conversation, contactNames: store.contactNames)
          .tag(conversation.id)
      }
    }
    .listStyle(.sidebar)
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
    .task { await store.send(.task).finish() }
  }
}

struct ConversationRow: View {
  let conversation: Conversation
  let contactNames: [String: String]

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
          Text(conversation.title(contactNames: contactNames))
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
