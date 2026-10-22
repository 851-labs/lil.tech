#if os(macOS)
  import ComposableArchitecture
  import Foundation
  import MessagesDatabase
  import MessagesThread
  import SQLiteData
  import SwiftUI
  import Tagged
  import Testing

  // A thread (`MessageThreadView`): the catalog `chat.db`'s group chat, then one-on-one threads
  // with Ada, seeded with made-up messages around `previewNow`. Synthetic data only. Stores have
  // no reducer, so a `.task` that runs before the image can't load over the seeded messages.

  extension MacSnapshotTests {
    @Test(arguments: messageThreadCatalog.selectedStates)
    func messageThread(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let messageThreadCatalog = StateCatalog(
    "Message Thread", width: 520, minHeight: 420,
    states: [
      CatalogState("Group", width: 500) {
        let messages = try! catalogChatDatabase.read { db in
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
              senderNames: catalogContactNames,
              hasEarlierMessages: false
            )
          ) {
            EmptyReducer()
          }
        )
      },
      CatalogState("Links") {
        thread(messages: [
          .catalog(1, "Your appointment is at 10:30 AM. Call (415) 555-0100 for changes."),
          .catalog(2, "Details here: https://example.com/appointments/confirm?id=8f3a2c"),
          .catalog(
            3,
            "https://example.com/a/really/long/path/that/keeps/going/and/going/to/check/wrapping?with=query&params=true"
          ),
          .catalog(4, "Thanks! I’ll call +1 415 555 0123 if I’m late", isFromMe: true),
          .catalog(5, "Sharing the menu: example.com/menu", isFromMe: true),
        ])
      },
      CatalogState("Delivered") {
        thread(messages: [
          .catalog(1, "Are we still on for lunch?"),
          .catalog(2, "Yes! Same place as last time?", isFromMe: true, isDelivered: true),
          .catalog(3, "I’ll grab us a table", isFromMe: true, isDelivered: true),
        ])
      },
      CatalogState("Read") {
        thread(messages: [
          .catalog(1, "Are we still on for lunch?"),
          .catalog(
            2, "Yes! Same place as last time?", isFromMe: true, isDelivered: true,
            dateRead: previewNow.addingTimeInterval(-120)
          ),
        ])
      },
      CatalogState("Replied After Read") {
        thread(messages: [
          .catalog(
            1, "Yes! Same place as last time?", isFromMe: true, isDelivered: true,
            dateRead: previewNow.addingTimeInterval(-300)
          ),
          .catalog(2, "Perfect, see you there"),
        ])
      },
      CatalogState("Edited and Not Delivered") {
        thread(messages: [
          .catalog(1, "Running 10 minutes late", dateEdited: previewNow),
          .catalog(2, "No worries!", isFromMe: true, hasError: true),
          .catalog(
            3, "Take your time, I just got here", isFromMe: true, isDelivered: true,
            dateEdited: previewNow),
        ])
      },
      CatalogState("Date Separators") {
        let day: TimeInterval = 24 * 3_600
        thread(messages: [
          .catalog(1, "Happy new year!", date: previewNow.addingTimeInterval(-400 * day)),
          .catalog(
            2, "Did you see the launch?", isFromMe: true,
            date: previewNow.addingTimeInterval(-9 * day)),
          .catalog(3, "Lunch Thursday?", date: previewNow.addingTimeInterval(-3 * day)),
          .catalog(
            4, "Sure!", isFromMe: true, date: previewNow.addingTimeInterval(-3 * day + 20 * 60)),
          .catalog(5, "Running late", date: previewNow.addingTimeInterval(-day)),
          .catalog(6, "Morning!", isFromMe: true, date: previewNow.addingTimeInterval(-3 * 3_600)),
          .catalog(7, "Hey 👋", date: previewNow.addingTimeInterval(-60)),
        ])
      },
      CatalogState("Text Message") {
        thread(
          chatGUID: "SMS;-;+14155550101",
          messages: [
            .catalog(1, "Your code is 123456", service: "SMS"),
            .catalog(2, "Thanks", isFromMe: true, isDelivered: true, service: "SMS"),
          ]
        )
      },
      CatalogState("Sending") {
        thread(
          messages: [.catalog(1, "Are we still on for lunch?")],
          pendingMessages: [
            MessageThreadFeature.PendingMessage(id: UUID(1), text: "On my way!", sentAt: previewNow)
          ]
        )
      },
      CatalogState("Send Failed") {
        thread(
          messages: [.catalog(1, "Are we still on for lunch?")],
          pendingMessages: [
            MessageThreadFeature.PendingMessage(
              id: UUID(1), text: "On my way!", sentAt: previewNow, isFailed: true)
          ]
        )
      },
      CatalogState("Wide Window", width: 1_100) {
        thread(messages: [
          .catalog(1, "So it’s a boy or girl"),
          .catalog(2, "boy", isFromMe: true),
          .catalog(3, "due in 3 weeks", isFromMe: true),
          .catalog(4, "Omg she’s super pregnant"),
          .catalog(5, "yes", isFromMe: true, isDelivered: true),
        ])
      },
      CatalogState("Spam") {
        thread(
          chatGUID: "SMS;-;+18885550123",
          messages: [
            .catalog(
              1, "Your package is on hold. Confirm your address at example.com/track",
              service: "SMS")
          ],
          filter: .spam
        )
      },
      CatalogState("Recently Deleted") {
        thread(
          messages: [
            .catalog(1, "Want to grab coffee next week?"),
            .catalog(2, "Sure, Tuesday works", isFromMe: true, isDelivered: true),
          ],
          filter: .recentlyDeleted
        )
      },
      CatalogState("Empty") { thread(messages: []) },
      CatalogState("Load Failed") { thread(messages: [], loadFailed: true) },
    ])

  /// A one-on-one thread with Ada, seeded with `messages`.
  @MainActor
  private func thread(
    chatGUID: String = "iMessage;-;+14155550101",
    messages: [ThreadMessage],
    pendingMessages: [MessageThreadFeature.PendingMessage] = [],
    loadFailed: Bool = false,
    filter: ConversationFilter = .messages
  ) -> some View {
    MessageThreadView(
      store: Store(
        initialState: MessageThreadFeature.State(
          chatID: 900,
          chatGUID: chatGUID,
          title: "Ada Lovelace",
          isGroup: false,
          messages: messages,
          pendingMessages: pendingMessages,
          hasEarlierMessages: false,
          loadFailed: loadFailed,
          filter: filter
        )
      ) {
        EmptyReducer()
      }
    )
  }

  extension ThreadMessage {
    /// A message sent `id` minutes after 10 minutes before `previewNow`, from Ada unless
    /// `isFromMe`.
    fileprivate static func catalog(
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
        guid: "catalog-thread-\(id)",
        date: date ?? previewNow.addingTimeInterval(Double(id - 10) * 60),
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
#endif
