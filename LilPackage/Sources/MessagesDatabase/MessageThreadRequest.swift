public import Foundation
public import SQLiteData
public import Tagged

public struct ThreadMessage: Equatable, Identifiable, Sendable {
  public let id: Message.ID
  public var guid: String
  public var date: Date
  public var text: String?
  public var attributedBody: Data?
  public var isFromMe: Bool
  public var senderAddress: String?
  public var hasAttachments: Bool
  public var service: String?
  public var isDelivered: Bool
  public var dateRead: Date?
  public var dateEdited: Date?
  /// Whether an outgoing message failed to send.
  public var hasError: Bool

  public init(
    id: Message.ID,
    guid: String,
    date: Date,
    text: String?,
    attributedBody: Data?,
    isFromMe: Bool,
    senderAddress: String?,
    hasAttachments: Bool,
    service: String? = "iMessage",
    isDelivered: Bool = false,
    dateRead: Date? = nil,
    dateEdited: Date? = nil,
    hasError: Bool = false
  ) {
    self.id = id
    self.guid = guid
    self.date = date
    self.text = text
    self.attributedBody = attributedBody
    self.isFromMe = isFromMe
    self.senderAddress = senderAddress
    self.hasAttachments = hasAttachments
    self.service = service
    self.isDelivered = isDelivered
    self.dateRead = dateRead
    self.dateEdited = dateEdited
    self.hasError = hasError
  }

  /// Whether the message went over SMS or RCS rather than iMessage, which Messages shows in green.
  public var isTextMessage: Bool {
    guard let service else { return false }
    return service.caseInsensitiveCompare("SMS") == .orderedSame
      || service.caseInsensitiveCompare("RCS") == .orderedSame
  }

  /// The message text, falling back to the text archived in `attributedBody`, without attachment
  /// placeholders.
  public var body: String {
    (text ?? attributedBody.flatMap(AttributedBody.text(from:)) ?? "")
      .replacing("\u{FFFC}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The position of this message in its thread, for loading the page of messages before it.
  public var cursor: MessageThreadRequest.Cursor {
    MessageThreadRequest.Cursor(date: date, id: id)
  }
}

/// Fetches a page of messages in one chat, returned oldest first.
///
/// Without a cursor, the page is the most recent `limit` messages. With a cursor, it's the
/// `limit` messages immediately before it. Tapbacks and group events are excluded.
///
/// Messages are ordered by `chat_message_join.message_date`, which matches `message.date` and lets
/// SQLite walk the `(chat_id, message_date, message_id)` index instead of sorting the thread.
public struct MessageThreadRequest: FetchKeyRequest {
  public var chatID: Chat.ID
  public var before: Cursor?
  public var limit: Int

  public init(chatID: Chat.ID, before: Cursor? = nil, limit: Int = 100) {
    self.chatID = chatID
    self.before = before
    self.limit = limit
  }

  public struct Cursor: Equatable, Hashable, Sendable {
    public var date: Date
    public var id: Message.ID

    public init(date: Date, id: Message.ID) {
      self.date = date
      self.id = id
    }
  }

  public func fetch(_ db: Database) throws -> [ThreadMessage] {
    let rows =
      try ChatMessageJoin
      .where { $0.chatID.eq(chatID) }
      .where {
        if let before {
          let beforeDate = Date.AppleTimestampRepresentation(queryOutput: before.date)
          $0.messageDate.lt(beforeDate)
            || ($0.messageDate.eq(beforeDate) && $0.messageID.lt(before.id))
        } else {
          true
        }
      }
      .order { ($0.messageDate.desc(), $0.messageID.desc()) }
      .join(Message.all) { $0.messageID.eq($1.id) }
      .leftJoin(Handle.all) { $1.handleID.eq($2.id) }
      .where { _, messages, _ in
        messages.associatedMessageType.eq(0) && messages.itemType.eq(0)
      }
      .limit(limit)
      .select { _, messages, handles in
        ThreadMessageRow.Columns(message: messages, senderAddress: handles.address)
      }
      .fetchAll(db)

    return rows.reversed().map { row in
      ThreadMessage(
        id: row.message.id,
        guid: row.message.guid,
        date: row.message.date,
        text: row.message.text,
        attributedBody: row.message.attributedBody,
        isFromMe: row.message.isFromMe,
        senderAddress: row.message.isFromMe ? nil : row.senderAddress,
        hasAttachments: row.message.hasAttachments,
        service: row.message.service,
        isDelivered: row.message.isDelivered,
        dateRead: row.message.dateRead,
        dateEdited: row.message.dateEdited,
        hasError: row.message.error != 0
      )
    }
  }
}

@Selection
private struct ThreadMessageRow {
  let message: Message
  let senderAddress: String?
}
