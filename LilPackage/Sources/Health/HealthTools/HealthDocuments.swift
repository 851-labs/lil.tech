import Foundation
import HealthDatabase
public import SQLiteData

// The Health Documents tools (851-4163): `health_documents` lists documents from their rows, in
// the words of the app's Health Documents page (`HealthDocumentsView.swift`), and
// `health_document` reads one document's CDA XML from its blob, a page of characters at a time,
// as the privacy policy says (851-4157). The remote server does the same
// (`Services/api/src/health/tools/HealthDocuments.ts`), rule for rule.

extension HealthTools {
  /// The most Health Documents `health_documents` lists.
  public static let healthDocumentsLimit = 100
  /// The most characters (UTF-16 code units) a page of a document's XML has, and its default:
  /// at most 240 KB as JSON, under the 256 KB ceiling.
  public static let healthDocumentPageLimit = 40_000

  // MARK: - health_documents

  /// The documents that start in the period, newest first, at most `healthDocumentsLimit`, with
  /// how many there are.
  public func healthDocuments(
    range: ToolRange, date: String? = nil, timeZone: String? = nil, _ db: Database
  ) throws -> HealthDocumentsResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    let period = try ToolPeriod(range, date: date, now: now, time: time)
    let (count, documents) = try HealthDatabase.healthDocuments(
      in: period.interval, limit: Self.healthDocumentsLimit, db)
    let zones = RecordedZones()
    return HealthDocumentsResult(
      timeZone: time.name, range: range.rawValue, start: time.localTime(period.start),
      end: time.localTime(period.end), count: count,
      documents: documents.map { document in
        let recorded = zones.times(
          json: document.metadata, start: document.startDate, end: document.endDate)
        return HealthDocumentItem(
          id: document.id, title: document.displayTitle,
          patient: HealthDocument.shown(document.patientName),
          author: HealthDocument.shown(document.authorName),
          custodian: HealthDocument.shown(document.custodianName),
          start: time.localTime(document.start),
          end: time.localTime(Date(unixMilliseconds: document.endDate)),
          recordedTimeZone: recorded.timeZone, recordedStart: recorded.start,
          recordedEnd: recorded.end, source: document.sourceName)
      })
  }

  // MARK: - health_document

  /// A page of a document's XML, as text (`documentText`): `limit` characters (UTF-16 code
  /// units) from the cursor, which is where the page starts.
  public func healthDocument(
    id: String, timeZone: String? = nil, cursor: String? = nil, limit: Int? = nil,
    _ db: Database
  ) throws -> HealthDocumentResult {
    let time = try ToolTime(timeZone: timeZone ?? defaultTimeZone)
    // Checked before the XML, which may have to be downloaded.
    let limit = limit ?? Self.healthDocumentPageLimit
    guard (1...Self.healthDocumentPageLimit).contains(limit) else {
      throw HealthToolError("The limit must be from 1 to \(Self.healthDocumentPageLimit).")
    }
    let invalidCursor = HealthToolError(
      "Invalid cursor: \(cursor ?? ""). Pass the previous page's nextCursor.")
    let start =
      try cursor.map { cursor in
        guard let index = Self.cursorIndex(cursor) else { throw invalidCursor }
        return index
      } ?? 0
    guard let document = try HealthDatabase.healthDocument(id: id, db) else {
      throw HealthToolError(
        "No Health Document with ID \(id). health_documents lists them, with their IDs.")
    }
    let units = Array(Self.documentText(try blob(document.xml)).utf16)
    // Past the end, or between a surrogate pair's halves, isn't where a page starts.
    guard start <= units.count,
      start == 0 || start == units.count
        || !(UTF16.isTrailSurrogate(units[start]) && UTF16.isLeadSurrogate(units[start - 1]))
    else { throw invalidCursor }
    let end = Self.documentPageEnd(units, start: start, limit: limit)
    return HealthDocumentResult(
      timeZone: time.name, id: document.id, title: document.displayTitle,
      start: time.localTime(document.start), length: units.count,
      offset: start, xml: String(decoding: units[start..<end], as: UTF16.self),
      nextCursor: end < units.count ? String(end) : nil)
  }

  /// Where a page of `limit` characters from `start` ends: never between a surrogate pair's
  /// halves, so before the pair, or after it when the page would otherwise be empty.
  static func documentPageEnd(_ units: [UTF16.CodeUnit], start: Int, limit: Int) -> Int {
    let end = min(start + limit, units.count)
    guard end < units.count, UTF16.isTrailSurrogate(units[end]),
      UTF16.isLeadSurrogate(units[end - 1])
    else { return end }
    return end - 1 > start ? end - 1 : end + 1
  }

  // MARK: - The XML as text

  /// A document's XML as text, as the remote server's `documentText` reads it: by its byte order
  /// mark (left out), else as UTF-16 if it starts `<?` in UTF-16, else by its XML declaration
  /// (ISO-8859-1 and US-ASCII as ISO-8859-1, and windows-1252), else as UTF-8, bytes UTF-8 can't
  /// read as U+FFFD. Not `ClinicalDocument.text(of:)`, the page's, which reads any encoding
  /// Foundation knows, and falls back to UTF-8 when one can't read a byte: a rule only Foundation
  /// has, which the server couldn't match.
  static func documentText(_ xml: Data) -> String {
    let bytes = [UInt8](xml)
    func startsWith(_ prefix: UInt8...) -> Bool { bytes.starts(with: prefix) }
    if startsWith(0xEF, 0xBB, 0xBF) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
    if startsWith(0xFF, 0xFE) { return utf16Text(bytes.dropFirst(2), littleEndian: true) }
    if startsWith(0xFE, 0xFF) { return utf16Text(bytes.dropFirst(2), littleEndian: false) }
    if startsWith(0x3C, 0x00, 0x3F, 0x00) { return utf16Text(bytes[...], littleEndian: true) }
    if startsWith(0x00, 0x3C, 0x00, 0x3F) { return utf16Text(bytes[...], littleEndian: false) }
    switch declaredEncoding(bytes) {
    case .latin1: return singleByteText(bytes, windows1252: false)
    case .windows1252: return singleByteText(bytes, windows1252: true)
    case .utf8: return String(decoding: bytes, as: UTF8.self)
    }
  }

  private enum DocumentEncoding {
    case utf8, latin1, windows1252
  }

  /// ISO-8859-1's names (IANA's, with its aliases), and US-ASCII's, read as ISO-8859-1.
  private static let latin1Names: Set<String> = [
    "iso-8859-1", "iso_8859-1", "iso_8859-1:1987", "iso-ir-100", "latin1", "l1", "ibm819",
    "cp819", "csisolatin1", "us-ascii", "ascii", "iso646-us", "us", "csascii",
  ]
  private static let windows1252Names: Set<String> = ["windows-1252", "cp1252", "cswindows1252"]

  /// The single-byte encoding an XML declaration names (`<?xml version="1.0"
  /// encoding="ISO-8859-1"?>`) in the XML's first 200 bytes, or UTF-8 for any other, or none.
  /// Read from the bytes, each a character (the declaration is ASCII), as the server reads it.
  private static func declaredEncoding(_ bytes: [UInt8]) -> DocumentEncoding {
    let head = bytes.prefix(200)
    guard head.starts(with: Array("<?xml".utf8)),
      let end = head.indices.first(where: {
        head[$0] == 0x3F && $0 + 1 < head.endIndex && head[$0 + 1] == 0x3E
      })
    else { return .utf8 }
    var declaration = String.UnicodeScalarView()
    declaration.append(contentsOf: head[..<end].map { Unicode.Scalar($0) })
    guard
      let match = String(declaration).firstMatch(
        of: /encoding[ \t\r\n]*=[ \t\r\n]*["']([A-Za-z0-9._:-]+)["']/.matchingSemantics(
          .unicodeScalar))
    else { return .utf8 }
    let name = match.output.1.lowercased()
    if latin1Names.contains(name) { return .latin1 }
    return windows1252Names.contains(name) ? .windows1252 : .utf8
  }

  /// UTF-16 code units as text, a lone surrogate (or an odd last byte) as U+FFFD.
  private static func utf16Text(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
    let bytes = Array(bytes)
    let units = stride(from: 0, to: bytes.count - 1, by: 2).map { index in
      littleEndian
        ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
        : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }
    let text = String(decoding: units, as: UTF16.self)
    return bytes.count % 2 == 1 ? text + "\u{FFFD}" : text
  }

  /// windows-1252's characters for 0x80 to 0x9F, WHATWG's: the five it leaves out are C1
  /// controls.
  private static let windows1252: [UInt32] = [
    0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160, 0x2039,
    0x152, 0x8D, 0x17D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178,
  ]

  /// Bytes as single-byte text: ISO-8859-1's (each byte its code point), or windows-1252's.
  private static func singleByteText(_ bytes: [UInt8], windows1252: Bool) -> String {
    var scalars = String.UnicodeScalarView()
    for byte in bytes {
      let value =
        windows1252 && (0x80...0x9F).contains(byte)
        ? Self.windows1252[Int(byte) - 0x80] : UInt32(byte)
      // Every value in the table is a scalar.
      scalars.append(Unicode.Scalar(value)!)
    }
    return String(scalars)
  }
}

// MARK: - Outputs

/// A Health Document, in the words of the Mac's Health Documents page.
public struct HealthDocumentItem: Codable, Equatable, Sendable {
  public var id: String
  /// Its title, or `Health Document` without one (`displayTitle`).
  public var title: String
  /// The page's Patient, Author and Custodian rows, `nil` where HealthKit found none.
  public var patient: String?
  public var author: String?
  public var custodian: String?
  public var start: String
  public var end: String
  /// The zone it was recorded in (`HKTimeZone`), when it's a name the tools take, and its start
  /// and end on that zone's clock (851-4177); `nil` without one, and left out of the JSON.
  public var recordedTimeZone: String? = nil
  public var recordedStart: String? = nil
  public var recordedEnd: String? = nil
  public var source: String

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, .id)
    try container.encode(title, .title)
    try container.encode(patient, .patient)
    try container.encode(author, .author)
    try container.encode(custodian, .custodian)
    try container.encode(start, .start)
    try container.encode(end, .end)
    try container.encodeIfPresent(recordedTimeZone, forKey: .recordedTimeZone)
    try container.encodeIfPresent(recordedStart, forKey: .recordedStart)
    try container.encodeIfPresent(recordedEnd, forKey: .recordedEnd)
    try container.encode(source, .source)
  }
}

public struct HealthDocumentsResult: HealthToolOutput {
  public var timeZone: String
  public var range: String
  public var start: String
  public var end: String
  public var count: Int
  public var documents: [HealthDocumentItem]
}

public struct HealthDocumentResult: HealthToolOutput {
  public var timeZone: String
  public var id: String
  public var title: String
  /// The document's date.
  public var start: String
  /// The XML's length, in UTF-16 code units, and where the page starts in it.
  public var length: Int
  public var offset: Int
  /// The page of the XML.
  public var xml: String
  public var nextCursor: String?

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(timeZone, .timeZone)
    try container.encode(id, .id)
    try container.encode(title, .title)
    try container.encode(start, .start)
    try container.encode(length, .length)
    try container.encode(offset, .offset)
    try container.encode(xml, .xml)
    try container.encode(nextCursor, .nextCursor)
  }
}
