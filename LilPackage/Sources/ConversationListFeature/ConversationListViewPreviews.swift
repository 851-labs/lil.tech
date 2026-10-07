import ComposableArchitecture
import Foundation
import MessagesDatabase
import SQLiteData
import SwiftUI
import Tagged

// Lives in its own file: previewing a file instruments its functions, and with ForEach rows that
// trips an assertion in SwiftUI's macOS List (TableViewListCore_Mac2). Keeping the view code in
// ConversationListView.swift leaves it uninstrumented, as in the app.

#Preview(
  traits: .dependencies {
    $0.chatDatabase = .constant(try makePreviewDatabase())
  }
) {
  let conversations = try! makePreviewDatabase().read { db in
    try ConversationsRequest().fetch(db)
  }
  NavigationSplitView {
    ConversationListView(
      store: Store(initialState: ConversationListFeature.State(conversations: conversations)) {
        ConversationListFeature()
      }
    )
    .navigationSplitViewColumnWidth(min: 240, ideal: 300)
  } detail: {
    Text("Detail")
  }
  .frame(width: 720, height: 480)
}

private func makePreviewDatabase() throws -> DatabaseQueue {
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
  return database
}
