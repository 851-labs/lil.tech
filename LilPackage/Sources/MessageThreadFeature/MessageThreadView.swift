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
      if let note = store.filter.readOnlyNote {
        Text(note)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity, minHeight: 64)
          .padding(.horizontal)
      } else {
        ComposerView(store: store)
          .frame(height: 64)
          .overlay(alignment: .topLeading) {
            if store.draft.isEmpty {
              Text(store.isTextChat ? "Text Message" : "iMessage")
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
            }
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

extension ConversationFilter {
  /// Shown in place of the composer for read-only threads.
  fileprivate var readOnlyNote: String? {
    switch self {
    case .messages: nil
    case .spam: "This conversation is in Spam."
    case .recentlyDeleted: "These messages were deleted. Messages keeps them for up to 30 days."
    }
  }
}
