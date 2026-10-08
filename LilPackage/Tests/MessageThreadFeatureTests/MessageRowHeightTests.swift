import AppKit
import ComposableArchitecture
import Foundation
import MessagesDatabase
import Tagged
import Testing

@testable import MessageThreadFeature

/// The arithmetic row heights must match a full Auto Layout pass on the real cells.
@MainActor
struct MessageRowHeightTests {
  @Test(arguments: [360.0, 520, 900])
  func arithmeticHeightsMatchAutoLayout(rowWidth: CGFloat) throws {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func message(
      _ id: Int64,
      _ text: String?,
      isFromMe: Bool = false,
      minutes: Double,
      isDelivered: Bool = false,
      dateEdited: Date? = nil,
      hasError: Bool = false,
      hasAttachments: Bool = false
    ) -> ThreadMessage {
      ThreadMessage(
        id: Message.ID(id),
        guid: "m\(id)",
        date: start.addingTimeInterval(minutes * 60),
        text: text,
        attributedBody: nil,
        isFromMe: isFromMe,
        senderAddress: isFromMe ? nil : (id.isMultiple(of: 3) ? "+15550000002" : "+15550000001"),
        hasAttachments: hasAttachments,
        isDelivered: isDelivered,
        dateEdited: dateEdited,
        hasError: hasError
      )
    }
    let messages = [
      message(1, "boy", minutes: 0),
      message(
        2, "Anyone up for a hike on Saturday? It’s supposed to be sunny all weekend.", minutes: 1),
      message(
        3,
        "Call (415) 555-0100 or see https://example.com/a/really/long/path/that/keeps/going/and/going?with=query",
        minutes: 2),
      message(4, "Running late 🥾🏃‍♀️", isFromMe: true, minutes: 3, dateEdited: start),
      message(5, nil, minutes: 200, hasAttachments: true),
      message(6, "Line one\nLine two\nLine three", minutes: 201),
      message(7, "No worries!", isFromMe: true, minutes: 202, hasError: true),
      message(
        8, "Take your time", isFromMe: true, minutes: 203, isDelivered: true, dateEdited: start),
    ]
    let pending = [
      MessageThreadFeature.PendingMessage(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        text: "On my way, see you in a bit!", sentAt: start.addingTimeInterval(600 * 60),
        isFailed: true)
    ]
    let store: StoreOf<MessageThreadFeature> = Store(
      initialState: MessageThreadFeature.State(
        chatID: 1,
        chatGUID: "iMessage;+;chat000000000000000001",
        title: "Weekend Plans",
        isGroup: true,
        messages: messages,
        senderNames: ["+15550000001": "Ada Lovelace"],
        pendingMessages: pending,
        hasEarlierMessages: false
      )
    ) {
      EmptyReducer<MessageThreadFeature.State, MessageThreadFeature.Action>()
    }
    _ = NSApplication.shared
    let viewController = MessageThreadViewController(store: store)
    _ = viewController.view

    let items = MessageThreadViewController.items(messages: messages, pendingMessages: pending)
    #expect(items.contains { if case .separator = $0 { true } else { false } })
    for item in items {
      let arithmetic = viewController.measureHeight(of: item, rowWidth: rowWidth)
      let autoLayout = viewController.fittingHeight(of: item, rowWidth: rowWidth)
      #expect(
        abs(arithmetic - autoLayout) <= 1,
        "\(item) at \(rowWidth)pt: \(arithmetic) vs \(autoLayout)")
      if case .separator = item { continue }
      #expect(arithmetic > 30, "\(item) measured real content")
    }
  }
}
