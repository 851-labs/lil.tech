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
    associatedMessageType: Int
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
  }
}
