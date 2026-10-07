public import ComposableArchitecture
import ContactNames
import ConversationListFeature
import MessageThreadFeature
import MessagesDatabase
import OnboardingFeature
import SQLiteData
public import SwiftUI

public struct AppView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      if let fullDiskAccessStore = store.scope(\.fullDiskAccess, action: \.fullDiskAccess) {
        FullDiskAccessView(store: fullDiskAccessStore)
      } else if store.hasFullDiskAccess == true {
        NavigationSplitView {
          ConversationListView(store: store.scope(\.conversationList, action: \.conversationList))
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
          if let threadStore = store.scope(\.thread, action: \.thread) {
            MessageThreadView(store: threadStore)
              .id(threadStore.chatID)
          } else {
            ContentUnavailableView(
              "No Conversation Selected",
              systemImage: "bubble.left.and.bubble.right"
            )
          }
        }
        .frame(minWidth: 720, minHeight: 480)
      } else {
        ProgressView()
          .frame(minWidth: 480, minHeight: 320)
      }
    }
    .task { await store.send(.task).finish() }
  }
}

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
  let database = try! makePreviewChatDatabase()
  let conversations = try! database.read { db in try ConversationsRequest().fetch(db) }
  let messages = try! database.read { db in
    try MessageThreadRequest(chatID: PreviewChatDatabase.groupChatID).fetch(db)
  }
  let contactNames = Dictionary(
    uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) }
  )
  var state = AppFeature.State()
  state.hasFullDiskAccess = true
  state.conversationList = ConversationListFeature.State(
    contactNames: contactNames,
    conversations: conversations,
    selection: PreviewChatDatabase.groupChatID
  )
  state.thread = MessageThreadFeature.State(
    chatID: PreviewChatDatabase.groupChatID,
    chatGUID: "iMessage;+;chat000000000000000001",
    title: "Weekend Plans",
    isGroup: true,
    messages: messages,
    senderNames: contactNames,
    hasEarlierMessages: false
  )
  return AppView(
    store: Store(initialState: state) {
      AppFeature()
    }
  )
  .frame(width: 900, height: 560)
}
