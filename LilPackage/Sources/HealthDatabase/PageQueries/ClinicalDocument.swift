public import Foundation

/// A Health Document's structured body, read from its CDA XML (HL7's Clinical Document
/// Architecture, namespace `urn:hl7-org:v3`) for the Mac's document viewer (851-2837): each
/// `<section>`'s `<title>` and narrative `<text>`, as paragraphs, lists and tables. The header
/// (patient, author, custodian) isn't read: HealthKit extracts it into the record's columns.
///
/// Coded entries (`<entry>`) aren't shown: in C-CDA they repeat their section's narrative, so
/// only a section with entries but no narrative counts as left out. Neither are images
/// (`<renderMultiMedia>`, `<observationMedia>`). A document with either says so
/// (`omitsContent`), so the viewer can point to its XML. Other elements the narrative doesn't
/// define show their text.
public struct ClinicalDocument: Equatable, Sendable {
  public var sections: [DocumentSection]
  /// Whether some of the document isn't in `sections`: sections with coded data but no
  /// narrative, or images.
  public var omitsContent: Bool

  public init(sections: [DocumentSection], omitsContent: Bool = false) {
    self.sections = sections
    self.omitsContent = omitsContent
  }

  /// Why a document's XML can't be shown as sections.
  public enum ReadError: Error, Equatable, Sendable {
    /// Not well-formed XML, first going wrong at `line`.
    case malformed(line: Int)
    /// Well-formed, but its root isn't a CDA `ClinicalDocument`.
    case notClinicalDocument
    /// No structured body: none at all, or an unstructured one (`nonXMLBody`, such as a PDF).
    case noStructuredBody
    /// A structured body with no section that has a title or text.
    case noReadableSections

    /// What the viewer says before showing the XML instead.
    public var reason: String {
      switch self {
      case .malformed(let line):
        "This document's XML isn't well-formed (line \(line)), so it can't be shown as a page."
      case .notClinicalDocument:
        "This document isn't a clinical document (CDA), so it can't be shown as a page."
      case .noStructuredBody:
        "This document has no structured text to show as a page."
      case .noReadableSections:
        "None of this document's sections have text to show as a page."
      }
    }
  }

  /// The CDA namespace. Elements in other namespaces aren't CDA's.
  static let namespace = "urn:hl7-org:v3"

  /// Reads a document's sections from its XML.
  public init(xml: Data) throws(ReadError) {
    let root = try XMLTree.parse(xml)
    guard root.is("ClinicalDocument") else { throw .notClinicalDocument }
    guard let body = root.child("component")?.child("structuredBody") else {
      throw .noStructuredBody
    }
    var reader = NarrativeReader()
    let sections = body.children("component").compactMap { $0.child("section") }
      .compactMap { reader.section($0) }
    guard !sections.isEmpty else { throw .noReadableSections }
    self.init(sections: sections, omitsContent: reader.omitsContent)
  }

  /// A document's XML as text, in its encoding: as its byte order mark says (which is left
  /// out), else as UTF-16 if it starts that way, else as its XML declaration says, else UTF-8.
  /// Bytes the encoding can't read are replaced.
  public static func text(of xml: Data) -> String {
    let marks: [(bytes: [UInt8], encoding: String.Encoding)] = [
      ([0xEF, 0xBB, 0xBF], .utf8), ([0xFF, 0xFE], .utf16LittleEndian),
      ([0xFE, 0xFF], .utf16BigEndian),
    ]
    for mark in marks where xml.starts(with: mark.bytes) {
      return decode(xml.dropFirst(mark.bytes.count), mark.encoding)
    }
    // `<?` in UTF-16 without a mark (XML 1.0, appendix F).
    if xml.starts(with: [0x3C, 0x00, 0x3F, 0x00]) { return decode(xml, .utf16LittleEndian) }
    if xml.starts(with: [0x00, 0x3C, 0x00, 0x3F]) { return decode(xml, .utf16BigEndian) }
    return decode(xml, declaredEncoding(xml) ?? .utf8)
  }

  /// The encoding an XML declaration names (`<?xml version="1.0" encoding="ISO-8859-1"?>`), by
  /// its IANA name, if it's one Foundation knows.
  static func declaredEncoding(_ xml: Data) -> String.Encoding? {
    let start = String(decoding: xml.prefix(200), as: UTF8.self)
    guard start.hasPrefix("<?xml"), let end = start.range(of: "?>") else { return nil }
    let declaration = start[..<end.lowerBound]
    guard
      let match = declaration.firstMatch(of: /encoding\s*=\s*["']([A-Za-z0-9._:-]+)["']/)
    else { return nil }
    let name = String(match.output.1)
    let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard encoding != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
  }

  private static func decode(_ data: Data, _ encoding: String.Encoding) -> String {
    if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }
    return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
  }
}

/// A `<section>`: its title, its narrative, and the sections nested in it.
public struct DocumentSection: Equatable, Sendable {
  /// Empty when the section has none.
  public var title: String
  public var blocks: [NarrativeBlock]
  public var sections: [DocumentSection]

  public init(title: String, blocks: [NarrativeBlock] = [], sections: [DocumentSection] = []) {
    self.title = title
    self.blocks = blocks
    self.sections = sections
  }
}

/// A block of a section's narrative.
public indirect enum NarrativeBlock: Equatable, Sendable {
  /// A `<paragraph>`, or text between blocks.
  case paragraph(NarrativeText)
  /// A `<list>`, each `<item>` its own blocks.
  case list(ordered: Bool, items: [[NarrativeBlock]])
  case table(NarrativeTable)
}

/// Text with its emphasis (`<content styleCode="Bold">`…), whitespace collapsed as HTML does.
/// Line breaks (`<br/>`) are `"\n"`.
public struct NarrativeText: Equatable, Sendable {
  public struct Run: Equatable, Sendable {
    public var text: String
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    /// Raised (`<sup>`) or lowered (`<sub>`): "10" then a superscript "9" is 10⁹, not 109.
    public var position: Position

    public init(
      _ text: String, isBold: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false,
      position: Position = .baseline
    ) {
      self.text = text
      self.isBold = isBold
      self.isItalic = isItalic
      self.isUnderlined = isUnderlined
      self.position = position
    }

    /// Whether it looks the same as `other`, so the two can be one run.
    func looksLike(_ other: Run) -> Bool {
      isBold == other.isBold && isItalic == other.isItalic
        && isUnderlined == other.isUnderlined && position == other.position
    }
  }

  public enum Position: Equatable, Sendable {
    case baseline, superscript, `subscript`
  }

  public var runs: [Run]

  public init(_ runs: [Run]) {
    self.runs = runs
  }

  public init(_ text: String) {
    self.runs = [Run(text)]
  }

  /// The runs, each joined to the one before when they look the same.
  init(merging runs: [Run]) {
    var merged: [Run] = []
    for run in runs {
      if let last = merged.last, last.looksLike(run) {
        merged[merged.count - 1].text += run.text
      } else {
        merged.append(run)
      }
    }
    self.runs = merged
  }

  /// The text without its emphasis.
  public var plain: String { runs.map(\.text).joined() }
}

/// A `<table>`: its caption and rows, header rows (`<thead>`) first.
public struct NarrativeTable: Equatable, Sendable {
  public struct Row: Equatable, Sendable {
    public var cells: [Cell]
    /// Whether it's in `<thead>`.
    public var isHeader: Bool

    public init(cells: [Cell], isHeader: Bool = false) {
      self.cells = cells
      self.isHeader = isHeader
    }
  }

  /// A `<th>` or `<td>`, or an empty one standing in for a cell spanning rows from above.
  public struct Cell: Equatable, Sendable {
    /// `nil` for an empty cell.
    public var text: NarrativeText?
    /// Whether it's a `<th>`.
    public var isHeader: Bool
    /// How many columns it spans (`colspan`).
    public var columnSpan: Int

    public init(text: NarrativeText?, isHeader: Bool = false, columnSpan: Int = 1) {
      self.text = text
      self.isHeader = isHeader
      self.columnSpan = columnSpan
    }
  }

  public var caption: NarrativeText?
  public var rows: [Row]

  public init(caption: NarrativeText? = nil, rows: [Row]) {
    self.caption = caption
    self.rows = rows
  }

  /// The most columns a row spans.
  public var columnCount: Int {
    rows.map { $0.cells.reduce(0) { $0 + $1.columnSpan } }.max() ?? 0
  }
}

// MARK: - Reading the narrative

/// Turns sections' elements into ``DocumentSection``s, noting what it leaves out.
private struct NarrativeReader {
  var omitsContent = false

  struct Style {
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var position = NarrativeText.Position.baseline

    /// With a `styleCode`'s emphasis added (its tokens are space-separated).
    func adding(styleCode: String?) -> Style {
      var style = self
      for code in (styleCode ?? "").split(separator: " ") {
        switch code {
        case "Bold": style.isBold = true
        case "Italics", "Emphasis": style.isItalic = true
        case "Underline": style.isUnderlined = true
        default: break
        }
      }
      return style
    }

    /// With an element's `styleCode` added.
    func adding(_ element: XMLTree.Element) -> Style {
      adding(styleCode: element.attributes["styleCode"])
    }
  }

  /// A section, or `nil` (noted as left out) if it has no title, text or readable subsections.
  mutating func section(_ element: XMLTree.Element) -> DocumentSection? {
    let title = element.child("title").flatMap { inlineText(of: $0) }?.plain ?? ""
    let blocks = element.child("text").map { blocks(of: $0) } ?? []
    let sections = element.children("component").compactMap { $0.child("section") }
      .compactMap { section($0) }
    let entries = element.children("entry")
    // Entries repeat the narrative, so they're only missed without one. Images are always.
    if (blocks.isEmpty && !entries.isEmpty) || entries.contains(where: \.containsMedia) {
      omitsContent = true
    }
    guard !title.isEmpty || !blocks.isEmpty || !sections.isEmpty else { return nil }
    return DocumentSection(title: title, blocks: blocks, sections: sections)
  }

  /// An element's content as blocks: paragraphs, lists and tables, with text between them as
  /// paragraphs of its own.
  mutating func blocks(of element: XMLTree.Element, style: Style = Style()) -> [NarrativeBlock] {
    var blocks: [NarrativeBlock] = []
    var runs = RunBuilder()
    add(element.children, style: style.adding(element), to: &blocks, runs: &runs)
    if let text = runs.finish() { blocks.append(.paragraph(text)) }
    return blocks
  }

  /// An element's content as one text, its blocks on lines of their own (a table cell's), in
  /// `style` and the element's own.
  mutating func inlineText(of element: XMLTree.Element, style: Style = Style()) -> NarrativeText? {
    let lines = blocks(of: element, style: style).flatMap { lines(of: $0) }
    var runs: [NarrativeText.Run] = []
    for (index, line) in lines.enumerated() {
      if index > 0 { runs.append(NarrativeText.Run("\n")) }
      runs += line.runs
    }
    return runs.isEmpty ? nil : NarrativeText(merging: runs)
  }

  private func lines(of block: NarrativeBlock) -> [NarrativeText] {
    switch block {
    case .paragraph(let text):
      return [text]
    case .list(_, let items):
      return items.flatMap { item in
        item.flatMap { lines(of: $0) }.enumerated().map { index, line in
          index == 0 ? NarrativeText([NarrativeText.Run("• ")] + line.runs) : line
        }
      }
    case .table(let table):
      return table.rows.map { row in
        NarrativeText(row.cells.compactMap(\.text?.plain).joined(separator: ", "))
      }
    }
  }

  private mutating func add(
    _ nodes: [XMLTree.Node], style: Style, to blocks: inout [NarrativeBlock],
    runs: inout RunBuilder
  ) {
    for node in nodes {
      switch node {
      case .text(let text):
        runs.append(text, style: style)
      case .element(let element):
        add(element, style: style, to: &blocks, runs: &runs)
      }
    }
  }

  private mutating func add(
    _ element: XMLTree.Element, style: Style, to blocks: inout [NarrativeBlock],
    runs: inout RunBuilder
  ) {
    func flush() {
      if let text = runs.finish() { blocks.append(.paragraph(text)) }
    }
    // Elements in another namespace show their text, as unknown ones do.
    let name = element.namespace == ClinicalDocument.namespace ? element.name : ""
    switch name {
    case "paragraph":
      flush()
      add(element.children, style: style.adding(element), to: &blocks, runs: &runs)
      flush()
    case "list":
      flush()
      let style = style.adding(element)
      var captionStyle = style
      captionStyle.isBold = true
      if let caption = element.child("caption"),
        let text = inlineText(of: caption, style: captionStyle)
      {
        blocks.append(.paragraph(text))
      }
      let items = element.children("item").map { self.blocks(of: $0, style: style) }
        .filter { !$0.isEmpty }
      if !items.isEmpty {
        blocks.append(.list(ordered: element.attributes["listType"] == "ordered", items: items))
      }
    case "table":
      flush()
      if let table = table(element, style: style.adding(element)) { blocks.append(.table(table)) }
    case "br":
      runs.appendBreak()
    case "content" where element.attributes["revised"] == "delete":
      // Struck from the document: not shown.
      break
    case "content", "linkHtml":
      add(element.children, style: style.adding(element), to: &blocks, runs: &runs)
    case "sup", "sub":
      var style = style.adding(element)
      style.position = name == "sup" ? .superscript : .subscript
      add(element.children, style: style, to: &blocks, runs: &runs)
    case "caption":
      var style = style.adding(element)
      style.isBold = true
      add(element.children, style: style, to: &blocks, runs: &runs)
    case "renderMultiMedia":
      omitsContent = true
    case "footnoteRef", "col", "colgroup":
      break
    default:
      // Unknown elements (and `footnote`): their text, in place.
      add(element.children, style: style, to: &blocks, runs: &runs)
    }
  }

  /// A table's rows, with cells spanning rows (`rowspan`) standing in for empty ones in the rows
  /// below, so later cells stay in their columns.
  private mutating func table(_ element: XMLTree.Element, style: Style) -> NarrativeTable? {
    var rows: [(element: XMLTree.Element, style: Style, isHeader: Bool)] = []
    for child in element.childElements {
      switch child.name {
      case "thead", "tbody", "tfoot":
        rows += child.children("tr").map {
          (element: $0, style: style.adding(child), isHeader: child.name == "thead")
        }
      case "tr":
        rows.append((element: child, style: style, isHeader: false))
      default:
        break
      }
    }
    let caption = element.child("caption").flatMap { inlineText(of: $0, style: style) }
    // Rows still to come under a cell spanning rows, and its columns, by its first column.
    var spanning: [Int: (rows: Int, columns: Int)] = [:]
    var tableRows: [NarrativeTable.Row] = []
    for row in rows {
      let style = row.style.adding(row.element)
      var cells: [NarrativeTable.Cell] = []
      var column = 0
      func skipSpanned() {
        while let span = spanning[column] {
          cells.append(NarrativeTable.Cell(text: nil, columnSpan: span.columns))
          spanning[column] = span.rows > 1 ? (span.rows - 1, span.columns) : nil
          column += span.columns
        }
      }
      for cell in row.element.childElements where cell.name == "th" || cell.name == "td" {
        skipSpanned()
        let columns = Self.span(cell.attributes["colspan"])
        cells.append(
          NarrativeTable.Cell(
            text: inlineText(of: cell, style: style), isHeader: cell.name == "th",
            columnSpan: columns))
        let rowSpan = Self.span(cell.attributes["rowspan"])
        if rowSpan > 1 { spanning[column] = (rowSpan - 1, columns) }
        column += columns
      }
      skipSpanned()
      if !cells.isEmpty {
        tableRows.append(NarrativeTable.Row(cells: cells, isHeader: row.isHeader))
      }
    }
    guard !tableRows.isEmpty || caption != nil else { return nil }
    return NarrativeTable(caption: caption, rows: tableRows)
  }

  /// A `colspan` or `rowspan`: 1 unless it's a number above 1, and at most 100.
  private static func span(_ value: String?) -> Int {
    min(100, max(1, value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1))
  }
}

/// Collects a paragraph's runs and collapses their whitespace as HTML does: runs of spaces, tabs
/// and newlines become one space, none at a line's start or end.
private struct RunBuilder {
  private var runs: [NarrativeText.Run] = []
  private var pendingSpace = false
  private var atLineStart = true

  mutating func append(_ text: String, style: NarrativeReader.Style) {
    var collapsed = String.UnicodeScalarView()
    // By scalar: "\r\n" is one `Character`.
    for scalar in text.unicodeScalars {
      if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
        if !atLineStart { pendingSpace = true }
      } else {
        if pendingSpace {
          // A space between runs has only what both have: it isn't underlined, bold or raised
          // unless both are.
          if collapsed.isEmpty, let last = runs.last {
            runs.append(
              NarrativeText.Run(
                " ", isBold: last.isBold && style.isBold, isItalic: last.isItalic && style.isItalic,
                isUnderlined: last.isUnderlined && style.isUnderlined,
                position: last.position == style.position ? last.position : .baseline))
          } else {
            collapsed.append(" ")
          }
        }
        pendingSpace = false
        atLineStart = false
        collapsed.append(scalar)
      }
    }
    guard !collapsed.isEmpty else { return }
    runs.append(
      NarrativeText.Run(
        String(collapsed), isBold: style.isBold, isItalic: style.isItalic,
        isUnderlined: style.isUnderlined, position: style.position))
  }

  mutating func appendBreak() {
    // None at the start.
    guard !runs.isEmpty else { return }
    pendingSpace = false
    atLineStart = true
    runs.append(NarrativeText.Run("\n"))
  }

  /// The text so far, or `nil` if it's empty, and starts over.
  mutating func finish() -> NarrativeText? {
    defer { self = RunBuilder() }
    // No line breaks at the end.
    while runs.last?.text == "\n" { runs.removeLast() }
    return runs.isEmpty ? nil : NarrativeText(merging: runs)
  }
}

// MARK: - The XML

/// A document's elements and text, from Foundation's `XMLParser`. Coded entries' content is left
/// out as it's read, since it's most of a large document and the viewer doesn't show it.
enum XMLTree {
  final class Element {
    /// Its local name, without a prefix.
    let name: String
    let namespace: String?
    let attributes: [String: String]
    var children: [Node] = []
    /// For an `<entry>`, whose content isn't kept: whether it has an image (`observationMedia`).
    var containsMedia = false

    init(name: String, namespace: String?, attributes: [String: String]) {
      self.name = name
      self.namespace = namespace
      self.attributes = attributes
    }

    /// Whether it's CDA's element of this name.
    func `is`(_ name: String) -> Bool {
      self.name == name && namespace == ClinicalDocument.namespace
    }

    var childElements: [Element] {
      children.compactMap {
        guard case .element(let element) = $0, element.namespace == ClinicalDocument.namespace
        else { return nil }
        return element
      }
    }

    /// CDA's child elements of this name.
    func children(_ name: String) -> [Element] {
      childElements.filter { $0.name == name }
    }

    func child(_ name: String) -> Element? {
      childElements.first { $0.name == name }
    }
  }

  enum Node {
    case element(Element)
    case text(String)
  }

  static func parse(_ xml: Data) throws(ClinicalDocument.ReadError) -> Element {
    let parser = XMLParser(data: xml)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    let builder = Builder()
    parser.delegate = builder
    let parsed = parser.parse()
    guard let root = builder.root else {
      throw parsed ? .notClinicalDocument : .malformed(line: max(1, parser.lineNumber))
    }
    guard parsed else { throw .malformed(line: max(1, parser.lineNumber)) }
    return root
  }

  private final class Builder: NSObject, XMLParserDelegate {
    var root: Element?
    private var stack: [Element] = []
    /// How deep inside an `<entry>` the parser is, whose content isn't kept.
    private var skipping = 0
    /// The entry being skipped.
    private var entry: Element?

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      if skipping > 0 {
        skipping += 1
        if elementName == "observationMedia", namespaceURI == ClinicalDocument.namespace {
          entry?.containsMedia = true
        }
        return
      }
      let element = Element(name: elementName, namespace: namespaceURI, attributes: attributes)
      if let parent = stack.last {
        parent.children.append(.element(element))
      } else {
        root = element
      }
      stack.append(element)
      if element.is("entry") {
        // Kept, empty, so its section knows it had one.
        stack.removeLast()
        skipping = 1
        entry = element
      }
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      if skipping > 0 {
        skipping -= 1
        return
      }
      stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA cdata: Data) {
      append(String(decoding: cdata, as: UTF8.self))
    }

    private func append(_ text: String) {
      guard skipping == 0, let parent = stack.last else { return }
      if case .text(let previous) = parent.children.last {
        parent.children[parent.children.count - 1] = .text(previous + text)
      } else {
        parent.children.append(.text(text))
      }
    }
  }
}
