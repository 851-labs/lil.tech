import ComposableArchitecture
import ContactNames
import MessagesDatabase
import SQLiteData
import SwiftUI

// Lives in its own file: previewing a file instruments its functions, and with ForEach rows that
// trips an assertion in SwiftUI's macOS List (TableViewListCore_Mac2). Keeping the view code in
// ConversationListView.swift leaves it uninstrumented, as in the app.

#Preview("Messages", traits: .previewChatDatabase) {
  ConversationListPreview(filter: .messages)
}

#Preview("Spam", traits: .previewChatDatabase) {
  ConversationListPreview(filter: .spam)
}

#Preview("Recently Deleted", traits: .previewChatDatabase) {
  ConversationListPreview(filter: .recentlyDeleted)
}

/// The sidebar showing `filter`, seeded from the preview `chat.db`.
private struct ConversationListPreview: View {
  let filter: ConversationFilter

  var body: some View {
    let conversations = try! makePreviewChatDatabase().read { db in
      try ConversationsRequest(filter: filter).fetch(db)
    }
    NavigationSplitView {
      ConversationListView(
        store: Store(
          initialState: ConversationListFeature.State(
            contactNames: Dictionary(
              uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) }
            ),
            conversations: conversations,
            filter: filter
          )
        ) {
          ConversationListFeature()
        }
      )
      .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
      Text("Detail")
    }
    .frame(width: 720, height: 480)
  }
}

extension PreviewTrait where T == Preview.ViewTraits {
  fileprivate static var previewChatDatabase: Self {
    .dependencies {
      $0.chatDatabase = .constant(try makePreviewChatDatabase())
      $0.contactNames = .constant(
        ContactIndex(
          PreviewChatDatabase.contactNames.map {
            ContactIndex.Contact(name: $0.name, phoneNumbers: [$0.address], emails: [$0.address])
          }
        )
      )
    }
  }
}
