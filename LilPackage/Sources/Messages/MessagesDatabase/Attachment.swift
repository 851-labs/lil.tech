public import SQLiteData
public import Tagged

@Table("attachment")
public struct Attachment: Identifiable, Sendable {
  public typealias ID = Tagged<Self, Int64>

  @Column("ROWID", primaryKey: true)
  public let id: ID
  public var guid: String
  public var filename: String?
  public var uti: String?
  @Column("mime_type")
  public var mimeType: String?
  /// The attachment's original file name, e.g. "IMG_0001.HEIC".
  @Column("transfer_name")
  public var transferName: String?
  @Column("is_sticker")
  public var isSticker: Bool
  /// Set for internal payloads, like link previews, that Messages never shows as attachments.
  @Column("hide_attachment")
  public var isHidden: Bool

  public init(
    id: ID,
    guid: String,
    filename: String? = nil,
    uti: String? = nil,
    mimeType: String?,
    transferName: String?,
    isSticker: Bool = false,
    isHidden: Bool = false
  ) {
    self.id = id
    self.guid = guid
    self.filename = filename
    self.uti = uti
    self.mimeType = mimeType
    self.transferName = transferName
    self.isSticker = isSticker
    self.isHidden = isHidden
  }
}

@Table("message_attachment_join")
public struct MessageAttachmentJoin: Sendable {
  @Column("message_id")
  public var messageID: Message.ID
  @Column("attachment_id")
  public var attachmentID: Attachment.ID

  public init(messageID: Message.ID, attachmentID: Attachment.ID) {
    self.messageID = messageID
    self.attachmentID = attachmentID
  }
}
