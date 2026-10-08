public import Foundation
public import SQLiteData
public import Tagged

@Table("message")
public struct Message: Identifiable, Sendable {
  public typealias ID = Tagged<Self, Int64>

  @Column("ROWID", primaryKey: true)
  public let id: ID
  public var guid: String
  public var text: String?
  public var attributedBody: Data?
  @Column("handle_id")
  public var handleID: Handle.ID
  public var service: String?
  @Column(as: Date.AppleTimestampRepresentation.self)
  public var date: Date
  @Column("is_from_me")
  public var isFromMe: Bool
  @Column("is_read")
  public var isRead: Bool
  @Column("cache_has_attachments")
  public var hasAttachments: Bool
  @Column("item_type")
  public var itemType: Int
  @Column("associated_message_type")
  public var associatedMessageType: Int
  /// For a tapback, the message it reacts to, e.g. "p:0/<guid>".
  @Column("associated_message_guid")
  public var associatedMessageGUID: String?
  /// For an emoji tapback, the emoji.
  @Column("associated_message_emoji")
  public var associatedMessageEmoji: String?
  @Column("is_delivered")
  public var isDelivered: Bool
  @Column("date_read", as: Date.OptionalAppleTimestampRepresentation.self)
  public var dateRead: Date?
  @Column("date_edited", as: Date.OptionalAppleTimestampRepresentation.self)
  public var dateEdited: Date?
  /// A nonzero error code when an outgoing message failed to send.
  public var error: Int

  public init(
    id: ID,
    guid: String,
    text: String?,
    attributedBody: Data?,
    handleID: Handle.ID,
    service: String?,
    date: Date,
    isFromMe: Bool,
    isRead: Bool,
    hasAttachments: Bool,
    itemType: Int,
    associatedMessageType: Int,
    associatedMessageGUID: String? = nil,
    associatedMessageEmoji: String? = nil,
    isDelivered: Bool = false,
    dateRead: Date? = nil,
    dateEdited: Date? = nil,
    error: Int = 0
  ) {
    self.id = id
    self.guid = guid
    self.text = text
    self.attributedBody = attributedBody
    self.handleID = handleID
    self.service = service
    self.date = date
    self.isFromMe = isFromMe
    self.isRead = isRead
    self.hasAttachments = hasAttachments
    self.itemType = itemType
    self.associatedMessageType = associatedMessageType
    self.associatedMessageGUID = associatedMessageGUID
    self.associatedMessageEmoji = associatedMessageEmoji
    self.isDelivered = isDelivered
    self.dateRead = dateRead
    self.dateEdited = dateEdited
    self.error = error
  }
}
