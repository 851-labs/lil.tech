public import Foundation
public import SQLiteData
public import Tagged

public struct Conversation: Equatable, Identifiable, Sendable {
  public let id: Chat.ID
  public var guid: String
  public var style: Chat.Style
  public var chatIdentifier: String
  public var displayName: String?
  public var participants: [String]
  public var latestMessage: LatestMessage

  public init(
    id: Chat.ID,
    guid: String,
    style: Chat.Style,
    chatIdentifier: String,
    displayName: String?,
    participants: [String],
    latestMessage: LatestMessage
  ) {
    self.id = id
    self.guid = guid
    self.style = style
    self.chatIdentifier = chatIdentifier
    self.displayName = displayName
    self.participants = participants
    self.latestMessage = latestMessage
  }

  public struct LatestMessage: Equatable, Sendable {
    public var date: Date
    public var text: String?
    public var attributedBody: Data?
    public var isFromMe: Bool
    public var hasAttachments: Bool
    /// Who sent it, for messages that aren't from me.
    public var senderAddress: String?
    /// Set when the latest message is a tapback.
    public var tapback: Tapback?
    /// For a tapback, the message it reacts to, or `nil` if that message is gone.
    public var reactedTo: ReactedMessage?
    /// The visible attachments, in order.
    public var attachments: [AttachmentSummary]
    /// Whether it's a voice message recorded in Messages.
    public var isAudioMessage: Bool

    public init(
      date: Date,
      text: String?,
      attributedBody: Data?,
      isFromMe: Bool,
      hasAttachments: Bool,
      senderAddress: String? = nil,
      tapback: Tapback? = nil,
      reactedTo: ReactedMessage? = nil,
      attachments: [AttachmentSummary] = [],
      isAudioMessage: Bool = false
    ) {
      self.date = date
      self.text = text
      self.attributedBody = attributedBody
      self.isFromMe = isFromMe
      self.hasAttachments = hasAttachments
      self.senderAddress = senderAddress
      self.tapback = tapback
      self.reactedTo = reactedTo
      self.attachments = attachments
      self.isAudioMessage = isAudioMessage
    }
  }

  public struct AttachmentSummary: Equatable, Sendable {
    public var mimeType: String?
    public var uti: String?
    public var transferName: String?
    public var isSticker: Bool

    public init(mimeType: String?, uti: String?, transferName: String?, isSticker: Bool = false) {
      self.mimeType = mimeType
      self.uti = uti
      self.transferName = transferName
      self.isSticker = isSticker
    }
  }

  public struct ReactedMessage: Equatable, Sendable {
    public var body: String
    public var hasAttachments: Bool

    public init(body: String, hasAttachments: Bool) {
      self.body = body
      self.hasAttachments = hasAttachments
    }
  }
}

/// The sidebar's filters, matching Messages.
public enum ConversationFilter: CaseIterable, Sendable {
  /// Every conversation except spam.
  case messages
  /// Conversations Messages moved to Spam.
  case spam
  /// Conversations with messages in Recently Deleted, previewing the latest deleted one.
  case recentlyDeleted
}

/// Fetches every conversation in `filter` that has at least one message, newest first.
///
/// The latest message can be a tapback, like in Messages, in which case the message it reacts to is
/// looked up too. Group events and tapback removals are ignored.
public struct ConversationsRequest: FetchKeyRequest {
  public var filter: ConversationFilter

  public init(filter: ConversationFilter = .messages) {
    self.filter = filter
  }

  public func fetch(_ db: Database) throws -> [Conversation] {
    let latestMessages =
      switch filter {
      case .messages, .spam: try latestMessageRows(db, spam: filter == .spam)
      case .recentlyDeleted: try latestDeletedMessageRows(db)
      }

    let reactedToGUIDs = latestMessages.compactMap { row in
      row.associatedMessageGUID.map(Tapback.reactedToGUID(fromAssociatedGUID:))
    }
    let reactedToMessages =
      reactedToGUIDs.isEmpty
      ? []
      : try Message.where { $0.guid.in(reactedToGUIDs) }.fetchAll(db)
    var reactedToByGUID: [String: Conversation.ReactedMessage] = [:]
    for message in reactedToMessages {
      reactedToByGUID[message.guid] = Conversation.ReactedMessage(
        body: messageBody(text: message.text, attributedBody: message.attributedBody),
        hasAttachments: message.hasAttachments
      )
    }

    let messageIDsWithAttachments = latestMessages.filter(\.hasAttachments).map(\.messageID)
    let attachmentRows =
      messageIDsWithAttachments.isEmpty
      ? []
      : try MessageAttachmentJoin
        .where { $0.messageID.in(messageIDsWithAttachments) }
        .join(Attachment.all) { $0.attachmentID.eq($1.id) }
        .where { _, attachment in !attachment.isHidden }
        .order { join, _ in join.attachmentID }
        .select { join, attachment in (join.messageID, attachment) }
        .fetchAll(db)
    var attachmentsByMessageID: [Message.ID: [Conversation.AttachmentSummary]] = [:]
    for (messageID, attachment) in attachmentRows {
      attachmentsByMessageID[messageID, default: []].append(
        Conversation.AttachmentSummary(
          mimeType: attachment.mimeType,
          uti: attachment.uti,
          transferName: attachment.transferName,
          isSticker: attachment.isSticker
        )
      )
    }

    let participants =
      try ChatHandleJoin
      .group(by: \.chatID)
      .join(Handle.all) { $0.handleID.eq($1.id) }
      .select { ($0.chatID, $1.address.jsonGroupArray(order: $1.address)) }
      .fetchAll(db)
    let participantsByChatID = Dictionary(uniqueKeysWithValues: participants)

    return latestMessages.compactMap { row in
      guard let date = row.date else { return nil }
      let tapback = Tapback(
        associatedMessageType: row.associatedMessageType,
        emoji: row.associatedMessageEmoji
      )
      return Conversation(
        id: row.chat.id,
        guid: row.chat.guid,
        style: row.chat.style,
        chatIdentifier: row.chat.chatIdentifier,
        displayName: row.chat.displayName,
        participants: participantsByChatID[row.chat.id] ?? [],
        latestMessage: Conversation.LatestMessage(
          date: date,
          text: row.text,
          attributedBody: row.attributedBody,
          isFromMe: row.isFromMe,
          hasAttachments: row.hasAttachments,
          senderAddress: row.isFromMe ? nil : row.senderAddress,
          tapback: tapback,
          reactedTo: tapback == nil
            ? nil
            : row.associatedMessageGUID.flatMap {
              reactedToByGUID[Tapback.reactedToGUID(fromAssociatedGUID: $0)]
            },
          attachments: attachmentsByMessageID[row.messageID] ?? [],
          isAudioMessage: row.isAudioMessage
        )
      )
    }
  }
}

extension ConversationsRequest {
  private func latestMessageRows(_ db: Database, spam: Bool) throws -> [LatestMessageRow] {
    let chats = Chat.where {
      if spam {
        $0.isFiltered.eq(Chat.spamFilterValue)
      } else {
        $0.isFiltered.neq(Chat.spamFilterValue)
      }
    }
    let messages =
      chats
      .group(by: \.id)
      .join(ChatMessageJoin.all) { $0.id.eq($1.chatID) }
      .join(Message.all) { $1.messageID.eq($2.id) }
      .leftJoin(Handle.all) { $2.handleID.eq($3.id) }
      .where { _, _, message, _ in message.itemType.eq(0) }
    return
      try messages
      .where { _, _, message, _ in
        // Plain messages, or tapbacks that add a reaction (`Tapback.associatedMessageTypes`).
        message.associatedMessageType.eq(0)
          || message.associatedMessageType.between(2000, and: 2006)
      }
      .order { _, _, message, _ in message.date.max().desc() }
      .select { chat, _, message, handle in
        LatestMessageRow.columns(chat: chat, message: message, handle: handle)
      }
      .fetchAll(db)
  }

  /// Like `latestMessageRows`, over the messages in Recently Deleted.
  private func latestDeletedMessageRows(_ db: Database) throws -> [LatestMessageRow] {
    let messages =
      Chat
      .group(by: \.id)
      .join(ChatRecoverableMessageJoin.all) { $0.id.eq($1.chatID) }
      .join(Message.all) { $1.messageID.eq($2.id) }
      .leftJoin(Handle.all) { $2.handleID.eq($3.id) }
      .where { _, _, message, _ in message.itemType.eq(0) }
    return
      try messages
      .where { _, _, message, _ in
        message.associatedMessageType.eq(0)
          || message.associatedMessageType.between(2000, and: 2006)
      }
      .order { _, _, message, _ in message.date.max().desc() }
      .select { chat, _, message, handle in
        LatestMessageRow.columns(chat: chat, message: message, handle: handle)
      }
      .fetchAll(db)
  }
}

@Selection
private struct LatestMessageRow {
  let chat: Chat
  let messageID: Message.ID
  @Column(as: Date.AppleTimestampRepresentation?.self)
  let date: Date?
  let text: String?
  let attributedBody: Data?
  let isFromMe: Bool
  let hasAttachments: Bool
  let senderAddress: String?
  let associatedMessageType: Int
  let associatedMessageGUID: String?
  let associatedMessageEmoji: String?
  let isAudioMessage: Bool
}

extension LatestMessageRow {
  /// The row for the latest of `message`, grouped by chat.
  fileprivate static func columns(
    chat: Chat.TableColumns,
    message: Message.TableColumns,
    handle: Optional<Handle>.TableColumns
  ) -> Columns {
    Columns(
      chat: chat,
      messageID: message.id,
      date: message.date.max(),
      text: message.text,
      attributedBody: message.attributedBody,
      isFromMe: message.isFromMe,
      hasAttachments: message.hasAttachments,
      senderAddress: handle.address,
      associatedMessageType: message.associatedMessageType,
      associatedMessageGUID: message.associatedMessageGUID,
      associatedMessageEmoji: message.associatedMessageEmoji,
      isAudioMessage: message.isAudioMessage
    )
  }
}
