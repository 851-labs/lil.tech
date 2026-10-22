public import Foundation
public import HealthKit

/// A Health Document's contents (851-2836), read out of `HKCDADocumentSample` with its XML
/// (`init(_:)`), so the encoding can be tested without HealthKit.
public struct DocumentRecord: Equatable, Sendable {
  public var id: UUID
  /// What HealthKit extracts from the XML. Any may be empty.
  public var title: String
  public var patientName: String
  public var authorName: String
  public var custodianName: String
  /// The CDA document, as Health keeps it.
  public var xml: Data
  /// Times, source, device and metadata (`HealthEncoder.provenance(of:)`).
  public var provenance: [String: JSONValue]

  public init(
    id: UUID, title: String, patientName: String, authorName: String, custodianName: String,
    xml: Data, provenance: [String: JSONValue]
  ) {
    self.id = id
    self.title = title
    self.patientName = patientName
    self.authorName = authorName
    self.custodianName = custodianName
    self.xml = xml
    self.provenance = provenance
  }
}

extension DocumentRecord {
  /// A document read with its XML (`HKDocumentQuery`'s `includeDocumentData`), or `nil` without
  /// it: samples from other queries never have it.
  public init?(_ sample: HKCDADocumentSample) {
    guard let document = sample.document, let xml = document.documentData else { return nil }
    self.init(
      id: sample.uuid, title: document.title, patientName: document.patientName,
      authorName: document.authorName, custodianName: document.custodianName, xml: xml,
      provenance: HealthEncoder.provenance(of: sample))
  }
}

extension HealthEncoder {
  public static let documentEntity = "health_document"

  /// A document's row and its XML as a blob (`HealthDocument` on the server). The row refers to
  /// the blob by its SHA-256.
  public static func document(_ document: DocumentRecord) -> (mutation: HealthMutation, blob: Data)
  {
    var row = document.provenance
    row["title"] = .string(document.title)
    row["patientName"] = .string(document.patientName)
    row["authorName"] = .string(document.authorName)
    row["custodianName"] = .string(document.custodianName)
    row["xml"] = .string(HealthBlob.sha256(document.xml))
    return (.upsert(documentEntity, id: id(document.id), row: row), document.xml)
  }
}
