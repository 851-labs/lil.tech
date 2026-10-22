public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// Health Documents, newest first, at most `limit`. Their XML is a blob, downloaded when one
  /// is opened.
  public static func healthDocuments(limit: Int, _ db: Database) throws -> [HealthDocument] {
    try HealthDocument
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }

  /// The document with this ID, or `nil` once it's no longer shared.
  public static func healthDocument(id: String, _ db: Database) throws -> HealthDocument? {
    try HealthDocument.find(id).fetchOne(db)
  }
}

extension HealthDocument {
  public var start: Date { Date(unixMilliseconds: startDate) }

  /// Who it's from, as the list says: its author, or else its custodian (the organization that
  /// keeps it). `nil` if HealthKit found neither.
  public var byline: String? {
    let author = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !author.isEmpty { return author }
    let custodian = custodianName.trimmingCharacters(in: .whitespacesAndNewlines)
    return custodian.isEmpty ? nil : custodian
  }
}
