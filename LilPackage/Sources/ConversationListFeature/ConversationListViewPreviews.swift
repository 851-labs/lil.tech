import ComposableArchitecture
import ContactNames
import MessagesDatabase
import SQLiteData
import SwiftUI

// Lives in its own file: previewing a file instruments its functions, and with ForEach rows that
// trips an assertion in SwiftUI's macOS List (TableViewListCore_Mac2). Keeping the view code in
// ConversationListView.swift leaves it uninstrumented, as in the app.

#Preview(
  traits: .dependencies {
    $0.chatDatabase = .constant(try makePreviewChatDatabase())
    $0.contactNames = .constant(
      ContactIndex(
        PreviewChatDatabase.contactNames.map {
          ContactIndex.Contact(name: $0.name, phoneNumbers: [$0.address], emails: [$0.address])
        }
      )
    )
  }
) {
  let conversations = try! makePreviewChatDatabase().read { db in
    try ConversationsRequest().fetch(db)
  }
  NavigationSplitView {
    ConversationListView(
      store: Store(
        initialState: ConversationListFeature.State(
          contactNames: Dictionary(
            uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) }
          ),
          conversations: conversations
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
