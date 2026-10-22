public import SQLiteData
public import Tagged

@Table("handle")
public struct Handle: Identifiable, Sendable {
  public typealias ID = Tagged<Self, Int64>

  @Column("ROWID", primaryKey: true)
  public let id: ID
  @Column("id")
  public var address: String
  public var service: String

  public init(id: ID, address: String, service: String) {
    self.id = id
    self.address = address
    self.service = service
  }
}
