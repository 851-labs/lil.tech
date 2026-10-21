public import Foundation

/// A Health Document's structured body, read from its CDA XML (HL7's Clinical Document
/// Architecture, namespace `urn:hl7-org:v3`) for the Mac's document viewer (851-2837): each
/// `<section>`'s `<title>` and narrative `<text>`, as paragraphs, lists and tables. The header
/// (patient, author, custodian) isn't read: HealthKit extracts it into the record's columns.
///
/// Coded entries (`<entry>`) aren't shown, and neither are images (`<renderMultiMedia>`): a
/// document with either says so (`omitsContent`), so the viewer can point to its XML. Other
/// elements the narrative doesn't define show their text.
public struct ClinicalDocument: Equatable, Sendable {
  public var sections: [DocumentSection]
  /// Whether some of the document isn't in `sections`: sections without a title or text, coded
  /// data, or images.
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

  /// A document's XML as text: UTF-8, or UTF-16 with a byte order mark.
  public static func text(of xml: Data) -> String {
    if xml.starts(with: [0xFF, 0xFE]) || xml.starts(with: [0xFE, 0xFF]),
      let text = String(data: xml, encoding: .utf16)
    {
      return text
    }
    return String(decoding: xml, as: UTF8.self)
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

    public init(
      _ text: String, isBold: Bool = false, isItalic: Bool = false, isUnderlined: Bool = false
    ) {
      self.text = text
      self.isBold = isBold
      self.isItalic = isItalic
      self.isUnderlined = isUnderlined
    }
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
      if let last = merged.last, last.isBold == run.isBold, last.isItalic == run.isItalic,
        last.isUnderlined == run.isUnderlined
      {
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

  public struct Cell: Equatable, Sendable {
    /// `nil` for an empty cell.
    public var text: NarrativeText?
    /// Whether it's a `<th>`.
    public var isHeader: Bool

    public init(text: NarrativeText?, isHeader: Bool = false) {
      self.text = text
      self.isHeader = isHeader
    }
  }

  public var caption: NarrativeText?
  public var rows: [Row]

  public init(caption: NarrativeText? = nil, rows: [Row]) {
    self.caption = caption
    self.rows = rows
  }

  /// The most cells in a row.
  public var columnCount: Int { rows.map(\.cells.count).max() ?? 0 }
}

// MARK: - Reading the narrative

/// Turns sections' elements into ``DocumentSection``s, noting what it leaves out.
private struct NarrativeReader {
  var omitsContent = false

  struct Style {
    var isBold = false
    var isItalic = false
    var isUnderlined = false

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
  }

  /// A section, or `nil` (noted as left out) if it has no title, text or readable subsections.
  mutating func section(_ element: XMLTree.Element) -> DocumentSection? {
    let title = element.child("title").flatMap { inlineText(of: $0) }?.plain ?? ""
    let blocks = element.child("text").map { blocks(of: $0) } ?? []
    let sections = element.children("component").compactMap { $0.child("section") }
      .compactMap { section($0) }
    if !element.children("entry").isEmpty { omitsContent = true }
    guard !title.isEmpty || !blocks.isEmpty || !sections.isEmpty else {
      omitsContent = true
      return nil
    }
    return DocumentSection(title: title, blocks: blocks, sections: sections)
  }

  /// An element's content as blocks: paragraphs, lists and tables, with text between them as
  /// paragraphs of its own.
  mutating func blocks(of element: XMLTree.Element) -> [NarrativeBlock] {
    var blocks: [NarrativeBlock] = []
    var runs = RunBuilder()
    add(element.children, style: Style(), to: &blocks, runs: &runs)
    if let text = runs.finish() { blocks.append(.paragraph(text)) }
    return blocks
  }

  /// An element's content as one text, its blocks on lines of their own (a table cell's).
  mutating func inlineText(of element: XMLTree.Element, style: Style = Style()) -> NarrativeText? {
    let lines = blocks(of: element).flatMap { lines(of: $0) }
    var runs: [NarrativeText.Run] = []
    for (index, line) in lines.enumerated() {
      if index > 0 { runs.append(NarrativeText.Run("\n")) }
      runs += line.runs.map { run in
        var run = run
        run.isBold = run.isBold || style.isBold
        return run
      }
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
      add(element.children, style: style, to: &blocks, runs: &runs)
      flush()
    case "list":
      flush()
      if let caption = element.child("caption"),
        let text = inlineText(of: caption, style: Style(isBold: true))
      {
        blocks.append(.paragraph(text))
      }
      let items = element.children("item").map { self.blocks(of: $0) }.filter { !$0.isEmpty }
      if !items.isEmpty {
        blocks.append(.list(ordered: element.attributes["listType"] == "ordered", items: items))
      }
    case "table":
      flush()
      if let table = table(element) { blocks.append(.table(table)) }
    case "br":
      runs.appendBreak()
    case "content" where element.attributes["revised"] == "delete":
      // Struck from the document: not shown.
      break
    case "content", "linkHtml", "sub", "sup":
      add(
        element.children, style: style.adding(styleCode: element.attributes["styleCode"]),
        to: &blocks, runs: &runs)
    case "caption":
      add(element.children, style: Style(isBold: true), to: &blocks, runs: &runs)
    case "renderMultiMedia":
      omitsContent = true
    case "footnoteRef", "col", "colgroup":
      break
    default:
      // Unknown elements (and `footnote`): their text, in place.
      add(element.children, style: style, to: &blocks, runs: &runs)
    }
  }

  private mutating func table(_ element: XMLTree.Element) -> NarrativeTable? {
    var rows: [NarrativeTable.Row] = []
    for child in element.childElements {
      switch child.name {
      case "thead":
        rows += child.children("tr").map { row($0, isHeader: true) }
      case "tbody", "tfoot":
        rows += child.children("tr").map { row($0, isHeader: false) }
      case "tr":
        rows.append(row(child, isHeader: false))
      default:
        break
      }
    }
    let caption = element.child("caption").flatMap { inlineText(of: $0) }
    rows.removeAll { $0.cells.isEmpty }
    guard !rows.isEmpty || caption != nil else { return nil }
    return NarrativeTable(caption: caption, rows: rows)
  }

  private mutating func row(_ element: XMLTree.Element, isHeader: Bool) -> NarrativeTable.Row {
    let cells = element.childElements.filter { $0.name == "th" || $0.name == "td" }.map { cell in
      NarrativeTable.Cell(text: inlineText(of: cell), isHeader: cell.name == "th")
    }
    return NarrativeTable.Row(cells: cells, isHeader: isHeader)
  }
}

/// Collects a paragraph's runs and collapses their whitespace as HTML does: runs of spaces, tabs
/// and newlines become one space, none at a line's start or end.
private struct RunBuilder {
  private var runs: [NarrativeText.Run] = []
  private var pendingSpace = false
  private var atLineStart = true

  mutating func append(_ text: String, style: NarrativeReader.Style) {
    var collapsed = ""
    for character in text {
      if character == " " || character == "\t" || character == "\n" || character == "\r" {
        if !atLineStart { pendingSpace = true }
      } else {
        if pendingSpace {
          // A space between runs ends the one before, so it isn't underlined or bold with the
          // next.
          if collapsed.isEmpty, !runs.isEmpty {
            runs[runs.count - 1].text += " "
          } else {
            collapsed.append(" ")
          }
        }
        pendingSpace = false
        atLineStart = false
        collapsed.append(character)
      }
    }
    guard !collapsed.isEmpty else { return }
    runs.append(
      NarrativeText.Run(
        collapsed, isBold: style.isBold, isItalic: style.isItalic,
        isUnderlined: style.isUnderlined))
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

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      if skipping > 0 {
        skipping += 1
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
