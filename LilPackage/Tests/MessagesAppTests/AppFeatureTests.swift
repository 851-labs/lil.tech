import ComposableArchitecture
import ConversationListFeature
import Foundation
import MessageThreadFeature
import MessagesApp
import MessagesDatabase
import OnboardingFeature
import Tagged
import Testing

@MainActor
struct AppFeatureTests {
  @Test
  func launchWithFullDiskAccess() async throws {
    let database = try makeInMemoryChatDatabase()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
    }

    await store.send(.task)
    await store.receive(\.accessChecked) {
      $0.hasFullDiskAccess = true
    }
  }

  @Test
  func launchWithoutFullDiskAccessThenGrant() async throws {
    let isGranted = LockIsolated(false)
    let database = try makeInMemoryChatDatabase()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.chatDatabase = ChatDatabase {
        guard isGranted.value else { throw AccessDenied() }
        return database
      }
    }

    await store.send(.task)
    await store.receive(\.accessChecked) {
      $0.hasFullDiskAccess = false
      $0.fullDiskAccess = FullDiskAccessFeature.State()
    }

    isGranted.setValue(true)
    await store.send(\.fullDiskAccess.appBecameActive) {
      $0.fullDiskAccess?.isChecking = true
    }
    await store.receive(\.fullDiskAccess.checkResponse) {
      $0.fullDiskAccess?.isChecking = false
    }
    await store.receive(\.fullDiskAccess.delegate.accessGranted) {
      $0.hasFullDiskAccess = true
      $0.fullDiskAccess = nil
    }
  }
}

extension AppFeatureTests {
  @Test
  func selectingAConversationOpensItsThread() async {
    let conversations = [
      Conversation(
        id: 1,
        guid: "iMessage;+;chat000000000000000001",
        style: .group,
        chatIdentifier: "chat000000000000000001",
        displayName: "Book Club",
        participants: ["+15550000001", "+15550000002"],
        latestMessage: Conversation.LatestMessage(
          date: Date(timeIntervalSinceReferenceDate: 800_000_000),
          text: "Hi",
          attributedBody: nil,
          isFromMe: false,
          hasAttachments: false
        )
      )
    ]
    var state = AppFeature.State()
    state.conversationList = ConversationListFeature.State(conversations: conversations)
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(\.conversationList.selectionChanged, 1) {
      $0.conversationList.selection = 1
      $0.thread = MessageThreadFeature.State(chatID: 1, title: "Book Club", isGroup: true)
    }
    await store.send(\.conversationList.selectionChanged, nil) {
      $0.conversationList.selection = nil
      $0.thread = nil
    }
  }
}

private struct AccessDenied: Error {}
