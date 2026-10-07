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

  public struct Style: Hashable, QueryBindable, RawRepresentable, Sendable {
    public var rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let group = Self(rawValue: 43)
    public static let oneOnOne = Self(rawValue: 45)
  }
}
