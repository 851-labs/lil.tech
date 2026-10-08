import ComposableArchitecture
import Foundation
import MessagesDatabase
import SQLiteData
import SwiftUI
import Tagged

// One preview per thread state. Each seeds its messages in the initial state so `RenderPreview`
// snapshots show them on the first frame.

#Preview(
  "Group",
  traits: .dependencies {
    $0.chatDatabase = .constant(try makePreviewChatDatabase())
  }
) {
  let messages = try! makePreviewChatDatabase().read { db in
    try MessageThreadRequest(chatID: PreviewChatDatabase.groupChatID).fetch(db)
  }
  MessageThreadView(
    store: Store(
      initialState: MessageThreadFeature.State(
        chatID: PreviewChatDatabase.groupChatID,
        chatGUID: "iMessage;+;chat000000000000000001",
        title: "Weekend Plans",
        isGroup: true,
        messages: messages,
        senderNames: Dictionary(
          uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) }
        ),
        hasEarlierMessages: false
      )
    ) {
      MessageThreadFeature()
    }
  )
  .frame(width: 500, height: 420)
}

#Preview("Links", traits: .emptyChatDatabase) {
  ThreadPreview(messages: [
    .preview(1, "Your appointment is at 10:30 AM. Call (415) 555-0100 for changes."),
    .preview(2, "Details here: https://example.com/appointments/confirm?id=8f3a2c"),
    .preview(
      3,
      "https://example.com/a/really/long/path/that/keeps/going/and/going/to/check/wrapping?with=query&params=true"
    ),
    .preview(4, "Thanks! I’ll call +1 415 555 0123 if I’m late", isFromMe: true),
    .preview(5, "Sharing the menu: example.com/menu", isFromMe: true),
  ])
}

#Preview("Delivered", traits: .emptyChatDatabase) {
  ThreadPreview(messages: [
    .preview(1, "Are we still on for lunch?"),
    .preview(2, "Yes! Same place as last time?", isFromMe: true, isDelivered: true),
    .preview(3, "I’ll grab us a table", isFromMe: true, isDelivered: true),
  ])
}

#Preview("Read", traits: .emptyChatDatabase) {
  ThreadPreview(messages: [
    .preview(1, "Are we still on for lunch?"),
    .preview(
      2, "Yes! Same place as last time?", isFromMe: true, isDelivered: true,
      dateRead: Date().addingTimeInterval(-120)
    ),
  ])
}

#Preview("Replied After Read", traits: .emptyChatDatabase) {
  ThreadPreview(messages: [
    .preview(
      1, "Yes! Same place as last time?", isFromMe: true, isDelivered: true,
      dateRead: Date().addingTimeInterval(-300)
    ),
    .preview(2, "Perfect, see you there"),
  ])
}

#Preview("Edited and Not Delivered", traits: .emptyChatDatabase) {
  ThreadPreview(messages: [
    .preview(1, "Running 10 minutes late", dateEdited: Date()),
    .preview(2, "No worries!", isFromMe: true, hasError: true),
    .preview(
      3, "Take your time, I just got here", isFromMe: true, isDelivered: true, dateEdited: Date()),
  ])
}

#Preview("Date Separators", traits: .emptyChatDatabase) {
  let day: TimeInterval = 24 * 3_600
  let now = Date()
  ThreadPreview(messages: [
    .preview(1, "Happy new year!", date: now.addingTimeInterval(-400 * day)),
    .preview(2, "Did you see the launch?", isFromMe: true, date: now.addingTimeInterval(-9 * day)),
    .preview(3, "Lunch Thursday?", date: now.addingTimeInterval(-3 * day)),
    .preview(4, "Sure!", isFromMe: true, date: now.addingTimeInterval(-3 * day + 20 * 60)),
    .preview(5, "Running late", date: now.addingTimeInterval(-day)),
    .preview(6, "Morning!", isFromMe: true, date: now.addingTimeInterval(-3 * 3_600)),
    .preview(7, "Hey 👋", date: now.addingTimeInterval(-60)),
  ])
}

#Preview("Text Message", traits: .emptyChatDatabase) {
  ThreadPreview(
    chatGUID: "SMS;-;+14155550101",
    messages: [
      .preview(1, "Your code is 123456", service: "SMS"),
      .preview(2, "Thanks", isFromMe: true, isDelivered: true, service: "SMS"),
    ]
  )
}

#Preview("Sending", traits: .emptyChatDatabase) {
  ThreadPreview(
    messages: [.preview(1, "Are we still on for lunch?")],
    pendingMessages: [
      MessageThreadFeature.PendingMessage(id: UUID(1), text: "On my way!", sentAt: Date())
    ]
  )
}

#Preview("Send Failed", traits: .emptyChatDatabase) {
  ThreadPreview(
    messages: [.preview(1, "Are we still on for lunch?")],
    pendingMessages: [
      MessageThreadFeature.PendingMessage(
        id: UUID(1), text: "On my way!", sentAt: Date(), isFailed: true)
    ]
  )
}

/// A one-on-one thread with Ada, seeded with `messages`.
private struct ThreadPreview: View {
  var chatGUID = "iMessage;-;+14155550101"
  var messages: [ThreadMessage]
  var pendingMessages: [MessageThreadFeature.PendingMessage] = []

  var body: some View {
    MessageThreadView(
      store: Store(
        initialState: MessageThreadFeature.State(
          chatID: 900,
          chatGUID: chatGUID,
          title: "Ada Lovelace",
          isGroup: false,
          messages: messages,
          pendingMessages: pendingMessages,
          hasEarlierMessages: false
        )
      ) {
        MessageThreadFeature()
      }
    )
    .frame(width: 520, height: 420)
  }
}

extension ThreadMessage {
  /// A message sent `id` minutes after a fixed start, from Ada unless `isFromMe`.
  fileprivate static func preview(
    _ id: Int64,
    _ text: String,
    isFromMe: Bool = false,
    isDelivered: Bool = false,
    dateRead: Date? = nil,
    dateEdited: Date? = nil,
    hasError: Bool = false,
    service: String = "iMessage",
    date: Date? = nil
  ) -> Self {
    ThreadMessage(
      id: Message.ID(900 + id),
      guid: "preview-thread-\(id)",
      date: date ?? Date().addingTimeInterval(Double(id - 10) * 60),
      text: text,
      attributedBody: nil,
      isFromMe: isFromMe,
      senderAddress: isFromMe ? nil : "+14155550101",
      hasAttachments: false,
      service: service,
      isDelivered: isDelivered,
      dateRead: dateRead,
      dateEdited: dateEdited,
      hasError: hasError
    )
  }
}

extension PreviewTrait where T == Preview.ViewTraits {
  /// An empty `chat.db`, so a preview's `.task` load doesn't replace its seeded messages.
  fileprivate static var emptyChatDatabase: Self {
    .dependencies { $0.chatDatabase = .constant(try makeInMemoryChatDatabase()) }
  }
}
