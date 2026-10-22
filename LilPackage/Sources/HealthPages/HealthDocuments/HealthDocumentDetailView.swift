import AppKit
import Dependencies
import Foundation
import HealthDatabase
import LilSync
import SQLiteData
import SwiftUI

/// A Health Document as a page: who it's about and from, then each section of its structured
/// body as a section of a grouped form, with its XML a button away. Its XML is a blob, downloaded when it opens, as an
/// ECG's voltages are. A document that can't be read as sections shows its XML instead. Follows
/// the document's row, so one no longer shared says so.
struct HealthDocumentDetailView: View {
  let opened: HealthDocument
  /// Read by the view's task, not in its initializer: a list's links make their destinations
  /// as they show, so reading then would touch the database for every row, previews included.
  @Fetch private var document: HealthDocument?? = nil
  @Dependency(\.blobCache) private var blobCache
  @State private var state = HealthDocumentDetailContent.State.loading

  /// Opens with `document` while its row is read.
  init(document: HealthDocument) {
    opened = document
  }

  var body: some View {
    // `nil` until read; then the row, or `nil` inside once it's no longer shared.
    let document = self.document ?? opened
    HealthDocumentDetailContent(document: document, state: state)
      .task {
        _ = try? await $document.load(
          HealthDocumentRequest(id: opened.id), scheduler: MainQueueScheduler())
      }
      // Again if sync brings the document with other XML.
      .task(id: document?.xml) {
        guard let sha256 = document?.xml else { return }
        state = .loading
        do {
          let read = await HealthDocumentDetailContent.State.reading(
            try await blobCache.data(for: sha256))
          // Not over a newer document's, or after the page has gone.
          try Task.checkCancellation()
          state = read
        } catch is CancellationError {
        } catch {
          state = .failed(error.localizedDescription)
        }
      }
  }
}

/// A document's row, or `nil` once it's no longer shared.
struct HealthDocumentRequest: FetchKeyRequest {
  let id: String

  func fetch(_ db: Database) throws -> HealthDocument?? {
    .some(try HealthDatabase.healthDocument(id: id, db))
  }
}

/// What a document's page shows, however it got its XML. `document` is `nil` once it's no longer
/// shared.
struct HealthDocumentDetailContent: View {
  enum State {
    case loading
    /// The XML is kept as it came, and only decoded as text when it's shown.
    case loaded(xml: Data, document: ClinicalDocument)
    /// Its XML, which can't be read as sections.
    case unreadable(xml: Data, ClinicalDocument.ReadError)
    case failed(String)

    /// The XML read as sections, or why it can't be.
    init(reading xml: Data) {
      do {
        self = .loaded(xml: xml, document: try ClinicalDocument(xml: xml))
      } catch {
        self = .unreadable(xml: xml, error)
      }
    }

    /// The same, off the main actor: documents can be megabytes.
    @concurrent static func reading(_ xml: Data) async -> Self {
      Self(reading: xml)
    }
  }

  let document: HealthDocument?
  let state: State
  @SwiftUI.State private var showsXML = false

  var body: some View {
    Group {
      if let document {
        page(document)
      } else {
        ContentUnavailableView(
          "No Longer Shared", systemImage: "doc.text",
          description: Text("This document was deleted or is no longer shared with lil health."))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(document?.displayTitle ?? "Health Document")
  }

  @ViewBuilder private func page(_ document: HealthDocument) -> some View {
    Group {
      switch state {
      case .unreadable(let xml, let error):
        // The XML fills the page, scrolling on its own, so this isn't a form, which grows to its
        // content: the document's details are plain rows above it.
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 12) {
            DocumentTitle(document: document)
            VStack(alignment: .leading, spacing: 8) {
              DocumentDetails(document: document)
            }
          }
          Label {
            Text("\(error.reason) Its XML is below.")
          } icon: {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
          DocumentXMLText(id: document.xml, xml: xml)
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      default:
        // A grouped form on its own background, as Metric Detail is (851-2989, 851-3004): who
        // it's about and from, then a section for each of the document's.
        Form {
          Section {
            DocumentTitle(document: document)
              .padding(.vertical, 4)
            DocumentDetails(document: document)
          }
          content
        }
        .formStyle(.grouped)
      }
    }
    .toolbar {
      ToolbarItem {
        if case .loaded = state {
          Button("Show XML", systemImage: "chevron.left.forwardslash.chevron.right") {
            showsXML = true
          }
          .help("Show the document's XML")
        }
      }
    }
    .sheet(isPresented: $showsXML) {
      if case .loaded(let xml, _) = state {
        DocumentXMLSheet(title: document.displayTitle, id: document.xml, xml: xml)
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch state {
    case .loading:
      Section {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 200)
      }
    case .failed(let reason):
      Section {
        ContentUnavailableView(
          "Couldn't Load the Document", systemImage: "exclamationmark.triangle",
          description: Text(reason)
        )
        // A form's row would otherwise give it only its ideal width, off center.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .loaded(_, let clinical):
      if clinical.omitsContent {
        Section {
          HStack(alignment: .firstTextBaseline) {
            Label(
              "Some of this document, such as coded data or images, isn't shown here.",
              systemImage: "info.circle")
            Spacer()
            Button("Show XML") { showsXML = true }
          }
          .foregroundStyle(.secondary)
        }
      }
      ForEach(Array(clinical.sections.enumerated()), id: \.offset) { _, section in
        DocumentSectionView(section: section)
      }
    case .unreadable:
      EmptyView()
    }
  }
}

/// The document's title.
struct DocumentTitle: View {
  let document: HealthDocument

  var body: some View {
    Text(document.displayTitle)
      .font(.largeTitle.bold())
      .textSelection(.enabled)
  }
}

/// Who the document is about, from and kept by, and when, as HealthKit read them: a row each.
struct DocumentDetails: View {
  let document: HealthDocument

  var body: some View {
    row("Patient", document.patientName)
    row("Author", document.authorName)
    row("Custodian", document.custodianName)
    LabeledContent("Date", value: document.start.formatted(date: .long, time: .shortened))
    LabeledContent("Source", value: document.sourceName)
  }

  /// A name, unless HealthKit found none.
  @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty {
      LabeledContent(label) {
        Text(value)
          .textSelection(.enabled)
      }
    }
  }
}

/// A section of a grouped form: its title as the header, then its narrative and its
/// subsections', in one row.
struct DocumentSectionView: View {
  let section: DocumentSection

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(Self.flattened(section).enumerated()), id: \.offset) { _, entry in
          if entry.depth > 0, !entry.section.title.isEmpty {
            Text(entry.section.title)
              .font(.headline)
              .padding(.top, 6)
          }
          NarrativeBlocksView(blocks: entry.section.blocks)
        }
        if section.blocks.isEmpty && section.sections.isEmpty {
          Text("No text in this section.")
            .foregroundStyle(.secondary)
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
    } header: {
      if !section.title.isEmpty {
        Text(section.title)
      }
    }
  }

  /// The section and those nested in it, in document order, each with how deep it is.
  static func flattened(_ section: DocumentSection, depth: Int = 0)
    -> [(depth: Int, section: DocumentSection)]
  {
    [(depth, section)] + section.sections.flatMap { flattened($0, depth: depth + 1) }
  }
}

/// A narrative's paragraphs, lists and tables.
struct NarrativeBlocksView: View {
  let blocks: [NarrativeBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        NarrativeBlockView(block: block)
      }
    }
  }
}

struct NarrativeBlockView: View {
  let block: NarrativeBlock

  var body: some View {
    switch block {
    case .paragraph(let text):
      Text(text.attributed)
        .fixedSize(horizontal: false, vertical: true)
    case .list(let ordered, let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(ordered ? "\(index + 1)." : "•")
              .monospacedDigit()
              .foregroundStyle(.secondary)
            NarrativeBlocksView(blocks: item)
          }
        }
      }
      .padding(.leading, 4)
    case .table(let table):
      NarrativeTableView(table: table)
    }
  }
}

/// A table, header rows shaded, with lines between rows.
struct NarrativeTableView: View {
  let table: NarrativeTable

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let caption = table.caption {
        Text(caption.attributed)
          .font(.subheadline.bold())
      }
      Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
          if index > 0 { Divider() }
          GridRow {
            ForEach(Array(Self.cells(row, columns: table.columnCount).enumerated()), id: \.offset) {
              _, cell in
              Text(cell.text?.attributed ?? AttributedString())
                .fontWeight(row.isHeader || cell.isHeader ? .semibold : nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(row.isHeader ? Color.primary.opacity(0.06) : .clear)
                .gridCellColumns(cell.columnSpan)
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
  }

  /// A row's cells, with empty ones after them to fill `columns`.
  static func cells(_ row: NarrativeTable.Row, columns: Int) -> [NarrativeTable.Cell] {
    let spanned = row.cells.reduce(0) { $0 + $1.columnSpan }
    return row.cells
      + Array(repeating: NarrativeTable.Cell(text: nil), count: max(0, columns - spanned))
  }
}

/// A document's XML in a sheet.
struct DocumentXMLSheet: View {
  let title: String
  /// The XML's blob (`HealthDocument.xml`), which says when it's other XML.
  let id: String
  let xml: Data
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text("XML")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
      Divider()
      DocumentXMLText(id: id, xml: xml)
    }
    .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
  }
}

/// XML as monospaced, selectable text. A text view rather than SwiftUI's `Text`, which lays out
/// all of a document at once: they can be megabytes. The XML is decoded as text when it's shown,
/// and again only when `id` changes, rather than compared on every update.
struct DocumentXMLText: NSViewRepresentable {
  /// The XML's blob (`HealthDocument.xml`), which says when it's other XML.
  let id: String
  let xml: Data

  final class Coordinator {
    /// The `id` of the XML shown.
    var shown: String?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    if let textView = scrollView.documentView as? NSTextView {
      textView.isEditable = false
      textView.isSelectable = true
      textView.isRichText = false
      textView.textContainerInset = NSSize(width: 6, height: 8)
      show(in: textView, context.coordinator)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView, context.coordinator.shown != id
    else { return }
    show(in: textView, context.coordinator)
  }

  private func show(in textView: NSTextView, _ coordinator: Coordinator) {
    coordinator.shown = id
    textView.string = ClinicalDocument.text(of: xml)
    textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    textView.textColor = .textColor
  }
}

extension NarrativeText {
  /// The text with its emphasis, for `Text`.
  var attributed: AttributedString {
    runs.reduce(into: AttributedString()) { result, run in
      var text = AttributedString(run.text)
      var intent: InlinePresentationIntent = []
      if run.isBold { intent.insert(.stronglyEmphasized) }
      if run.isItalic { intent.insert(.emphasized) }
      if !intent.isEmpty { text.inlinePresentationIntent = intent }
      if run.isUnderlined { text.underlineStyle = .single }
      if run.position != .baseline {
        // Smaller, and raised or lowered: 10⁹ isn't 109.
        var font = Font.caption
        if run.isBold { font = font.bold() }
        if run.isItalic { font = font.italic() }
        text.font = font
        text.baselineOffset = run.position == .superscript ? 5 : -3
      }
      result += text
    }
  }
}
