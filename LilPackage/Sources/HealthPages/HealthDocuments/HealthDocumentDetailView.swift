import AppKit
import Dependencies
import Foundation
import HealthDatabase
import LilSync
import SwiftUI

/// A Health Document as a page: who it's about and from, then each section of its structured
/// body as a card, with its XML a button away. Its XML is a blob, downloaded when it opens, as an
/// ECG's voltages are. A document that can't be read as sections shows its XML instead.
struct HealthDocumentDetailView: View {
  let document: HealthDocument
  @Dependency(\.blobCache) private var blobCache
  @State private var state = HealthDocumentDetailContent.State.loading

  var body: some View {
    HealthDocumentDetailContent(document: document, state: state)
      .task(id: document.xml) {
        state = .loading
        do {
          state = await .reading(try await blobCache.data(for: document.xml))
        } catch is CancellationError {
        } catch {
          state = .failed(error.localizedDescription)
        }
      }
  }
}

/// What a document's page shows, however it got its XML.
struct HealthDocumentDetailContent: View {
  enum State {
    case loading
    case loaded(xml: String, document: ClinicalDocument)
    /// Its XML, which can't be read as sections.
    case unreadable(xml: String, ClinicalDocument.ReadError)
    case failed(String)

    /// The XML read, off the main actor: documents can be megabytes.
    @concurrent static func reading(_ xml: Data) async -> Self {
      let text = ClinicalDocument.text(of: xml)
      do {
        return .loaded(xml: text, document: try ClinicalDocument(xml: xml))
      } catch {
        return .unreadable(xml: text, error)
      }
    }
  }

  let document: HealthDocument
  let state: State
  @SwiftUI.State private var showsXML = false

  var body: some View {
    Group {
      switch state {
      case .unreadable(let xml, let error):
        // The XML fills the page, scrolling on its own.
        VStack(alignment: .leading, spacing: 16) {
          DocumentHeader(document: document)
          Label {
            Text("\(error.reason) Its XML is below.")
          } icon: {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
          }
          DocumentXMLText(xml: xml)
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      default:
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            DocumentHeader(document: document)
            content
          }
          .padding(24)
          .frame(maxWidth: 860, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .background(Color.pageBackground)
    .navigationTitle(document.displayTitle)
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
        DocumentXMLSheet(title: document.displayTitle, xml: xml)
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, minHeight: 200)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load the Document", systemImage: "exclamationmark.triangle",
        description: Text(reason))
    case .loaded(_, let clinical):
      if clinical.omitsContent {
        HStack(alignment: .firstTextBaseline) {
          Label(
            "Some of this document, such as coded data or images, isn't shown here.",
            systemImage: "info.circle")
          Spacer()
          Button("Show XML") { showsXML = true }
        }
        .foregroundStyle(.secondary)
      }
      ForEach(Array(clinical.sections.enumerated()), id: \.offset) { _, section in
        DocumentSectionCard(section: section)
      }
    case .unreadable:
      EmptyView()
    }
  }
}

/// The document's title, and who it's about, from and kept by, and when, as HealthKit read them.
struct DocumentHeader: View {
  let document: HealthDocument

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(document.displayTitle)
        .font(.largeTitle.bold())
        .textSelection(.enabled)
      VStack(alignment: .leading, spacing: 8) {
        row("Patient", document.patientName)
        row("Author", document.authorName)
        row("Custodian", document.custodianName)
        LabeledContent(
          "Date", value: document.start.formatted(date: .long, time: .shortened))
        LabeledContent("Source", value: document.sourceName)
      }
      .padding(14)
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
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

/// A section as a card: its title and narrative, then its subsections'.
struct DocumentSectionCard: View {
  let section: DocumentSection

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(Self.flattened(section).enumerated()), id: \.offset) { _, entry in
        if !entry.section.title.isEmpty {
          Text(entry.section.title)
            .font(entry.depth == 0 ? .title3.bold() : .headline)
            .padding(.top, entry.depth == 0 ? 0 : 6)
        }
        NarrativeBlocksView(blocks: entry.section.blocks)
      }
      if section.blocks.isEmpty && section.sections.isEmpty {
        Text("No text in this section.")
          .foregroundStyle(.secondary)
      }
    }
    .textSelection(.enabled)
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
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
            ForEach(0..<table.columnCount, id: \.self) { column in
              let cell = column < row.cells.count ? row.cells[column] : nil
              Text(cell?.text?.attributed ?? AttributedString())
                .fontWeight(row.isHeader || cell?.isHeader == true ? .semibold : nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(row.isHeader ? Color.primary.opacity(0.06) : .clear)
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
  }
}

/// A document's XML in a sheet.
struct DocumentXMLSheet: View {
  let title: String
  let xml: String
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
      DocumentXMLText(xml: xml)
    }
    .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
  }
}

/// XML as monospaced, selectable text. A text view rather than SwiftUI's `Text`, which lays out
/// all of a document at once: they can be megabytes.
struct DocumentXMLText: NSViewRepresentable {
  let xml: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    if let textView = scrollView.documentView as? NSTextView {
      textView.isEditable = false
      textView.isSelectable = true
      textView.isRichText = false
      textView.textContainerInset = NSSize(width: 6, height: 8)
      show(xml, in: textView)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView, textView.string != xml else {
      return
    }
    show(xml, in: textView)
  }

  private func show(_ xml: String, in textView: NSTextView) {
    textView.string = xml
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
      result += text
    }
  }
}
