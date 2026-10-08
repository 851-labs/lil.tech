import AppKit
import ComposableArchitecture
import Foundation
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

@testable import MessageThreadFeature

/// Drives the real thread view controller in an offscreen window: scrolling to the top loads
/// earlier pages, keeps the message that was on screen in place, and stops at the first message.
@MainActor
struct MessageThreadPagingTests {
  @Test
  func scrollingToTheTopPagesBackWithoutJumping() async throws {
    let messageCount = 250
    let database = try makeThreadDatabase(messageCount: messageCount)
    let store = Store(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "Ada Lovelace",
        isGroup: false
      )
    ) {
      MessageThreadFeature()
    } withDependencies: {
      $0.chatDatabase = .constant(database)
      $0.chatDatabaseChanges = ChatDatabaseChanges { AsyncStream { $0.finish() } }
    }

    _ = NSApplication.shared
    let viewController = MessageThreadViewController(store: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = viewController.view
    viewController.view.layoutSubtreeIfNeeded()
    let scrollView = try #require(viewController.view as? NSScrollView)
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let clipView = scrollView.contentView

    let task = store.send(.task)
    try await waitUntil { store.messages.count == MessageThreadFeature.pageSize }
    viewController.view.layoutSubtreeIfNeeded()
    #expect(clipView.bounds.maxY >= tableView.bounds.height - 1, "Starts at the latest message")

    for expectedCount in [200, messageCount] {
      let anchorID = try #require(store.messages.first?.id)
      clipView.scroll(to: .zero)
      scrollView.reflectScrolledClipView(clipView)
      let anchorRow = try #require(viewController.row(forMessage: anchorID))
      let anchorOffset = tableView.rect(ofRow: anchorRow).minY - clipView.bounds.minY

      try await waitUntil { store.messages.count == expectedCount }
      viewController.view.layoutSubtreeIfNeeded()

      let newAnchorRow = try #require(viewController.row(forMessage: anchorID))
      let newAnchorOffset = tableView.rect(ofRow: newAnchorRow).minY - clipView.bounds.minY
      #expect(newAnchorRow > anchorRow, "Earlier messages were prepended")
      #expect(abs(newAnchorOffset - anchorOffset) < 1, "The anchor message didn't move")
    }
    #expect(store.messages.first?.id == 1)
    #expect(!store.hasEarlierMessages)

    clipView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(clipView)
    try await Task.sleep(for: .milliseconds(100))
    #expect(store.messages.count == messageCount, "Stops at the first message")
    #expect(!store.isLoadingEarlier)

    task.cancel()
    window.close()
  }
}

private func makeThreadDatabase(messageCount: Int) throws -> DatabaseQueue {
  let database = try makeInMemoryChatDatabase()
  try database.write { db in
    try db.seed {
      Handle(id: 1, address: "+15550000001", service: "iMessage")
      Chat(
        id: 1,
        guid: "iMessage;-;+15550000001",
        style: .oneOnOne,
        chatIdentifier: "+15550000001",
        serviceName: "iMessage",
        displayName: nil,
        isArchived: false
      )
    }
    for index in 1...messageCount {
      let date = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) * 60)
      // Vary lengths so rows have different heights.
      let text = String(repeating: "Message \(index) ", count: index % 7 + 1)
      try db.seed {
        Message(
          id: Message.ID(Int64(index)),
          guid: "message-\(index)",
          text: text,
          attributedBody: nil,
          handleID: index.isMultiple(of: 2) ? 0 : 1,
          service: "iMessage",
          date: date,
          isFromMe: index.isMultiple(of: 2),
          isRead: true,
          hasAttachments: false,
          itemType: 0,
          associatedMessageType: 0
        )
        ChatMessageJoin(chatID: 1, messageID: Message.ID(Int64(index)), messageDate: date)
      }
    }
  }
  return database
}

/// Spins the main run loop until `condition` holds, so effects, observation and AppKit layout run.
@MainActor
private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("Timed out waiting for condition")
      return
    }
    spinMainRunLoop()
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func spinMainRunLoop() {
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
