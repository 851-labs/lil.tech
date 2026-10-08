public import SQLiteData
public import Tagged

@Table("chat")
public struct Chat: Identifiable, Sendable {
  public typealias ID = Tagged<Self, Int64>

  @Column("ROWID", primaryKey: true)
  public let id: ID
  public var guid: String
  public var style: Style
  @Column("chat_identifier")
  public var chatIdentifier: String
  @Column("service_name")
  public var serviceName: String?
  @Column("display_name")
  public var displayName: String?
  @Column("is_archived")
  public var isArchived: Bool
  /// How Messages filtered the chat: 0 for known senders, 1 for unknown senders, and
  /// `Chat.spamFilterValue` for spam.
  @Column("is_filtered")
  public var isFiltered: Int

  /// The `is_filtered` value of chats Messages moved to Spam.
  public static let spamFilterValue = 2

  public init(
    id: ID,
    guid: String,
    style: Style,
    chatIdentifier: String,
    serviceName: String?,
    displayName: String?,
    isArchived: Bool,
    isFiltered: Int = 0
  ) {
    self.id = id
    self.guid = guid
    self.style = style
    self.chatIdentifier = chatIdentifier
    self.serviceName = serviceName
    self.displayName = displayName
    self.isArchived = isArchived
    self.isFiltered = isFiltered
  }

  public struct Style: Hashable, QueryBindable, RawRepresentable, Sendable {
    public var rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let group = Self(rawValue: 43)
    public static let oneOnOne = Self(rawValue: 45)
  }
}
