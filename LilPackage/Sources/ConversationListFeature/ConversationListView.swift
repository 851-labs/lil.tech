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
      Section {
        ForEach(store.conversations) { conversation in
          ConversationRow(conversation: conversation, contactNames: store.contactNames)
            .tag(conversation.id)
        }
      } header: {
        if store.filter != .messages {
          Text(store.filter.title)
        }
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
        switch store.filter {
        case .messages:
          ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right")
        case .spam:
          ContentUnavailableView("No Spam", systemImage: "xmark.bin")
        case .recentlyDeleted:
          ContentUnavailableView(
            "No Recently Deleted Messages",
            systemImage: "trash",
            description: Text("Deleted messages stay here for up to 30 days.")
          )
        }
      }
    }
    .toolbar {
      ToolbarItem {
        Menu {
          Picker("Filter", selection: $store.filter.sending(\.filterChanged)) {
            ForEach(ConversationFilter.allCases, id: \.self) { filter in
              Text(filter.title).tag(filter)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        } label: {
          Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .help("Filter Conversations")
      }
    }
    .task(id: store.filter) { await store.send(.task).finish() }
  }
}

extension ConversationFilter {
  var title: String {
    switch self {
    case .messages: "Messages"
    case .spam: "Spam"
    case .recentlyDeleted: "Recently Deleted"
    }
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
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        Text(conversation.previewText(contactNames: contactNames))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }
}
