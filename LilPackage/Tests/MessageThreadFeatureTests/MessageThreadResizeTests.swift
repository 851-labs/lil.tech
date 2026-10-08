import AppKit
import ComposableArchitecture
import Foundation
import MessagesDatabase
import SQLiteData
import Tagged
import Testing

@testable import MessageThreadFeature

/// Resizes the real thread view controller in an offscreen window, like dragging the sidebar
/// divider, and checks bubbles keep hugging their text.
@MainActor
struct MessageThreadResizeTests {
  @Test
  func bubblesHugTheirTextAfterResizing() async throws {
    let messages = ["boy", "due in 3 weeks", "What is diaper raffle lol", "yes"].enumerated().map {
      index, text in
      ThreadMessage(
        id: Message.ID(Int64(index + 1)),
        guid: "message-\(index + 1)",
        date: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) * 60),
        text: text,
        attributedBody: nil,
        isFromMe: index.isMultiple(of: 2),
        senderAddress: index.isMultiple(of: 2) ? nil : "+15550000001",
        hasAttachments: false
      )
    }
    let store: StoreOf<MessageThreadFeature> = Store(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;-;+15550000001",
        title: "Ada Lovelace",
        isGroup: false,
        messages: messages,
        hasEarlierMessages: false
      )
    ) {
      EmptyReducer<MessageThreadFeature.State, MessageThreadFeature.Action>()
    }

    _ = NSApplication.shared
    let viewController = MessageThreadViewController(store: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = viewController.view
    defer { window.close() }

    func bubbleWidths() throws -> [CGFloat] {
      viewController.view.layoutSubtreeIfNeeded()
      let scrollView = try #require(viewController.view as? NSScrollView)
      let tableView = try #require(scrollView.documentView as? NSTableView)
      return try messages.map { message in
        let row = try #require(viewController.row(forMessage: message.id))
        let cell = try #require(
          tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MessageCellView
        )
        cell.layoutSubtreeIfNeeded()
        return cell.bubbleFrame.width
      }
    }

    let initial = try bubbleWidths()
    #expect(initial.allSatisfy { $0 < 250 }, "Short messages get short bubbles: \(initial)")

    for width in [1_100.0, 500, 900, 700] {
      window.setContentSize(NSSize(width: width, height: 500))
      let widths = try bubbleWidths()
      for (before, after) in zip(initial, widths) {
        #expect(abs(before - after) < 1, "At \(width)pt wide: \(widths) vs \(initial)")
      }
    }
  }
}
