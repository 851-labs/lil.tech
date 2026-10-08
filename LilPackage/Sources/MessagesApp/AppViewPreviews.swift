import ComposableArchitecture
import ContactNames
import ConversationListFeature
import MessageThreadFeature
import MessagesDatabase
import OnboardingFeature
import SQLiteData
import SwiftUI

// One preview per app state. Each seeds its state so `RenderPreview` snapshots show it on the
// first frame.

#Preview("Checking Access", traits: .previewChatDatabase) {
  // Without a reducer, the access check in the view's `.task` can't finish before the snapshot.
  AppView(store: Store(initialState: AppFeature.State()) { EmptyReducer() })
}

#Preview("Needs Full Disk Access", traits: .previewChatDatabase) {
  var state = AppFeature.State()
  state.hasFullDiskAccess = false
  state.fullDiskAccess = FullDiskAccessFeature.State()
  return AppView(store: Store(initialState: state) { AppFeature() })
}

#Preview("Nothing Selected", traits: .previewChatDatabase) {
  AppView(store: Store(initialState: loadedState(selection: nil)) { AppFeature() })
}

#Preview("Thread Open", traits: .previewChatDatabase) {
  AppView(
    store: Store(initialState: loadedState(selection: PreviewChatDatabase.groupChatID)) {
      AppFeature()
    }
  )
}

/// The app with Full Disk Access, the preview conversations loaded, and `selection` open.
private func loadedState(selection: Chat.ID?) -> AppFeature.State {
  let database = try! makePreviewChatDatabase()
  let conversations = try! database.read { db in try ConversationsRequest().fetch(db) }
  let contactNames = Dictionary(
    uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) }
  )
  var state = AppFeature.State()
  state.hasFullDiskAccess = true
  state.conversationList = ConversationListFeature.State(
    contactNames: contactNames,
    conversations: conversations,
    selection: selection
  )
  if let selection, let conversation = conversations.first(where: { $0.id == selection }) {
    let messages = try! database.read { db in
      try MessageThreadRequest(chatID: selection).fetch(db)
    }
    state.thread = MessageThreadFeature.State(
      chatID: selection,
      chatGUID: conversation.guid,
      title: conversation.title(contactNames: contactNames),
      isGroup: conversation.style == .group,
      messages: messages,
      senderNames: contactNames,
      hasEarlierMessages: false
    )
  }
  return state
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
