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

  /// The documents that start in `range`, newest first (then by ID), at most `limit`, and how
  /// many there are in all: the `health_documents` tool's (851-4163).
  public static func healthDocuments(in range: Range<Date>, limit: Int, _ db: Database) throws
    -> (count: Int, documents: [HealthDocument])
  {
    let (lower, upper) = (range.lowerBound.unixMilliseconds, range.upperBound.unixMilliseconds)
    let inRange = HealthDocument.where { $0.startDate >= lower && $0.startDate < upper }
    let documents = try inRange.order { ($0.startDate.desc(), $0.id.desc()) }.limit(limit)
      .fetchAll(db)
    // Counted only when they don't all fit.
    return (documents.count < limit ? documents.count : try inRange.fetchCount(db), documents)
  }

  /// The document with this ID, or `nil` once it's no longer shared.
  public static func healthDocument(id: String, _ db: Database) throws -> HealthDocument? {
    try HealthDocument.find(id).fetchOne(db)
  }
}

extension HealthDocument {
  public var start: Date { Date(unixMilliseconds: startDate) }

  /// Its title, or a generic one if HealthKit found none, as its page and the list show it, and
  /// the document tools give it (851-4163).
  public var displayTitle: String {
    Self.shown(title) ?? "Health Document"
  }

  /// A title or name HealthKit read, without the whitespace around it, or `nil` if that's all it
  /// is, as the document's page shows its rows.
  public static func shown(_ name: String) -> String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  /// Who it's from, as the list says: its author, or else its custodian (the organization that
  /// keeps it). `nil` if HealthKit found neither.
  public var byline: String? {
    Self.shown(authorName) ?? Self.shown(custodianName)
  }
}
