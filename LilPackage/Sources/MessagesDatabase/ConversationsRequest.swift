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

    public init(
      date: Date,
      text: String?,
      attributedBody: Data?,
      isFromMe: Bool,
      hasAttachments: Bool
    ) {
      self.date = date
      self.text = text
      self.attributedBody = attributedBody
      self.isFromMe = isFromMe
      self.hasAttachments = hasAttachments
    }
  }
}

/// Fetches every conversation that has at least one message, newest first.
///
/// The latest message ignores tapbacks and group events, so the preview always shows something
/// that someone actually wrote.
public struct ConversationsRequest: FetchKeyRequest {
  public init() {}

  public func fetch(_ db: Database) throws -> [Conversation] {
    let latestMessages =
      try Chat
      .group(by: \.id)
      .join(ChatMessageJoin.all) { $0.id.eq($1.chatID) }
      .join(Message.all) { $1.messageID.eq($2.id) }
      .where { $2.associatedMessageType.eq(0) && $2.itemType.eq(0) }
      .order { $2.date.max().desc() }
      .select {
        LatestMessageRow.Columns(
          chat: $0,
          date: $2.date.max(),
          text: $2.text,
          attributedBody: $2.attributedBody,
          isFromMe: $2.isFromMe,
          hasAttachments: $2.hasAttachments
        )
      }
      .fetchAll(db)

    let participants =
      try ChatHandleJoin
      .group(by: \.chatID)
      .join(Handle.all) { $0.handleID.eq($1.id) }
      .select { ($0.chatID, $1.address.jsonGroupArray(order: $1.address)) }
      .fetchAll(db)
    let participantsByChatID = Dictionary(uniqueKeysWithValues: participants)

    return latestMessages.compactMap { row in
      guard let date = row.date else { return nil }
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
          hasAttachments: row.hasAttachments
        )
      )
    }
  }
}

@Selection
private struct LatestMessageRow {
  let chat: Chat
  @Column(as: Date.AppleTimestampRepresentation?.self)
  let date: Date?
  let text: String?
  let attributedBody: Data?
  let isFromMe: Bool
  let hasAttachments: Bool
}
