import HealthDatabase
import SwiftUI

// A grouped form's look for lists too long to be a `Form`: All Data and Food (851-3005), and the
// record lists (workouts, ECGs, audiograms, beat-to-beat measurements, Health Documents, State of
// Mind and assessments, 851-3032), which hold 500 to 2,000 records at most. A grouped
// `Form` builds every row at once on macOS, however few are on screen (851-2820): 1,000 rows took
// 3.9 s and 10,000 took 51 s on macOS 27, and 100,000 crashed it. These draw what it draws, from
// a `LazyVStack`, so only the rows on screen are built: its background and its sections' fill
// (`.background` and `.background.secondary`, the colors it paints), its width and insets, its
// bold section headers, and its rows' insets and separators.

/// A lazily built page in a grouped form's look. Its content is `LazyFormHeader`s,
/// `LazyFormRow`s and `LazyFormFooter`s, one after another. A list of records builds its sections
/// with `LazyFormSections` or `LazyFormSection`, which give each row its place in its section
/// (851-3036).
struct LazyForm<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(LazyFormMetrics.pageInset)
      .frame(maxWidth: LazyFormMetrics.sectionWidth + 2 * LazyFormMetrics.pageInset)
      .frame(maxWidth: .infinity)
    }
    .background(.background)
  }
}

/// A section's header, as a grouped form's: bold, over its rows' text.
struct LazyFormHeader: View {
  let title: String
  /// The page's first section has no section above it to keep clear of.
  let isFirst: Bool

  var body: some View {
    Text(title)
      .font(.headline)
      .accessibilityAddTraits(.isHeader)
      .padding(.horizontal, LazyFormMetrics.rowInset)
      .padding(.top, isFirst ? 0 : 30)
      .padding(.bottom, 10)
  }
}

/// A section's footer, as a grouped form's: a note under its rows, in secondary text.
struct LazyFormFooter: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.horizontal, LazyFormMetrics.rowInset)
      .padding(.top, 6)
  }
}

/// A row of a section, as a grouped form's: its content, on the section's fill, rounded at the
/// section's top and bottom, with a separator above it unless it's the first. A navigation row
/// (`showsChevron`, the label of a plain-styled `NavigationLink`) ends in a chevron.
struct LazyFormRow<Content: View>: View {
  let isFirst: Bool
  /// False for the last row loaded while its section may go on in the next page, so the section
  /// stays open.
  let isLast: Bool
  /// A navigation row's chevron. Rows that open nothing (a chart, a log) have none.
  var showsChevron = true
  @ViewBuilder let content: Content

  var body: some View {
    let radius = LazyFormMetrics.cornerRadius
    VStack(spacing: 0) {
      if !isFirst {
        // Half a `Divider`'s strength, as light as a grouped form's separators.
        Divider()
          .opacity(0.5)
          .padding(.horizontal, LazyFormMetrics.rowInset)
      }
      HStack(spacing: 10) {
        content
        if showsChevron {
          Image(systemName: "chevron.right")
            .font(.caption.bold())
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, LazyFormMetrics.rowInset)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .background(
      .background.secondary,
      in: UnevenRoundedRectangle(
        topLeadingRadius: isFirst ? radius : 0, bottomLeadingRadius: isLast ? radius : 0,
        bottomTrailingRadius: isLast ? radius : 0, topTrailingRadius: isFirst ? radius : 0,
        style: .continuous))
  }
}

/// Sections of records one after another, each under its title (a month, a day), as the record
/// lists show them (`sections(_:by:calendar:startDate:)`'s), and All Data and Food their days,
/// newest first.
struct LazyFormSections<Section, Record: Identifiable, Destination: View, Row: View>: View {
  let sections: [Section]
  /// A section's start, which tells it apart from the others.
  let start: KeyPath<Section, Date>
  let records: KeyPath<Section, [Record]>
  let title: (Section) -> String
  /// Whether the first section is the page's first, rather than under a chart.
  let isFirst: Bool
  /// Whether the last section may go on in the next page of a list that loads a page at a time,
  /// so it stays open while that loads (851-3040).
  let isOpen: Bool
  let destination: ((Record) -> Destination)?
  let row: (Record) -> Row

  /// Sections whose records open `destination`.
  init(
    _ sections: [Section], start: KeyPath<Section, Date>, records: KeyPath<Section, [Record]>,
    title: @escaping (Section) -> String, isFirst: Bool = true, isOpen: Bool = false,
    @ViewBuilder destination: @escaping (Record) -> Destination,
    @ViewBuilder row: @escaping (Record) -> Row
  ) {
    self.init(
      sections: sections, start: start, records: records, title: title, isFirst: isFirst,
      isOpen: isOpen, destination: destination, row: row)
  }

  /// `sections(_:by:calendar:startDate:)`'s sections, whose records open `destination`.
  init(
    _ sections: [Section], title: @escaping (Date) -> String, isFirst: Bool = true,
    @ViewBuilder destination: @escaping (Record) -> Destination,
    @ViewBuilder row: @escaping (Record) -> Row
  ) where Section == (start: Date, records: [Record]) {
    self.init(
      sections: sections, start: \.start, records: \.records, title: { title($0.start) },
      isFirst: isFirst, isOpen: false, destination: destination, row: row)
  }

  fileprivate init(
    sections: [Section], start: KeyPath<Section, Date>, records: KeyPath<Section, [Record]>,
    title: @escaping (Section) -> String, isFirst: Bool, isOpen: Bool,
    destination: ((Record) -> Destination)?, row: @escaping (Record) -> Row
  ) {
    self.sections = sections
    self.start = start
    self.records = records
    self.title = title
    self.isFirst = isFirst
    self.isOpen = isOpen
    self.destination = destination
    self.row = row
  }

  var body: some View {
    let first = sections.first?[keyPath: start]
    let last = sections.last?[keyPath: start]
    ForEach(sections, id: start) { section in
      let sectionStart = section[keyPath: start]
      LazyFormSection(
        title: title(section), isFirst: isFirst && sectionStart == first,
        isOpen: isOpen && sectionStart == last, records: section[keyPath: records],
        destination: destination, row: row)
    }
  }
}

extension LazyFormSections where Destination == Never {
  /// `sections(_:by:calendar:startDate:)`'s sections, whose records open nothing, so their rows
  /// have no chevron.
  init(
    _ sections: [Section], title: @escaping (Date) -> String, isFirst: Bool = true,
    @ViewBuilder row: @escaping (Record) -> Row
  ) where Section == (start: Date, records: [Record]) {
    self.init(
      sections: sections, start: \.start, records: \.records, title: { title($0.start) },
      isFirst: isFirst, isOpen: false, destination: nil, row: row)
  }
}

/// A section of records: its header, when it has a title, then a row for each record, the
/// section's corners on the first and the last. A record opens `destination`, when there's one,
/// as a navigation row.
struct LazyFormSection<Records: RandomAccessCollection, Destination: View, Row: View>: View
where Records.Element: Identifiable {
  let title: String?
  /// Whether the section is the page's first, with no section above it to keep clear of.
  let isFirst: Bool
  /// Whether the section may go on in the next page of a list that loads a page at a time, so
  /// its last loaded row stays open, with no bottom corners, while that loads (851-3040).
  let isOpen: Bool
  let records: Records
  let destination: ((Records.Element) -> Destination)?
  let row: (Records.Element) -> Row

  /// A section whose records open `destination`.
  init(
    _ title: String? = nil, isFirst: Bool = true, isOpen: Bool = false, records: Records,
    @ViewBuilder destination: @escaping (Records.Element) -> Destination,
    @ViewBuilder row: @escaping (Records.Element) -> Row
  ) {
    self.init(
      title: title, isFirst: isFirst, isOpen: isOpen, records: records, destination: destination,
      row: row)
  }

  fileprivate init(
    title: String?, isFirst: Bool, isOpen: Bool, records: Records,
    destination: ((Records.Element) -> Destination)?, row: @escaping (Records.Element) -> Row
  ) {
    self.title = title
    self.isFirst = isFirst
    self.isOpen = isOpen
    self.records = records
    self.destination = destination
    self.row = row
  }

  var body: some View {
    if let title {
      LazyFormHeader(title: title, isFirst: isFirst)
    }
    ForEach(records) { record in
      let isFirstRow = record.id == records.first?.id
      let isLastRow = !isOpen && record.id == records.last?.id
      if let destination {
        NavigationLink {
          destination(record)
        } label: {
          LazyFormRow(isFirst: isFirstRow, isLast: isLastRow) {
            row(record)
          }
        }
        .buttonStyle(.plain)
      } else {
        LazyFormRow(isFirst: isFirstRow, isLast: isLastRow, showsChevron: false) {
          row(record)
        }
      }
    }
  }
}

extension LazyFormSection where Destination == Never {
  /// A section whose records open nothing, so their rows have no chevron.
  init(
    _ title: String? = nil, isFirst: Bool = true, isOpen: Bool = false, records: Records,
    @ViewBuilder row: @escaping (Records.Element) -> Row
  ) {
    self.init(
      title: title, isFirst: isFirst, isOpen: isOpen, records: records, destination: nil,
      row: row)
  }
}

/// A grouped form's measurements on macOS 27.
private enum LazyFormMetrics {
  /// Between the page's edges and its sections.
  static let pageInset: CGFloat = 20
  /// A section's width at most.
  static let sectionWidth: CGFloat = 700
  /// Between a section's edges and its rows' content, and its separators.
  static let rowInset: CGFloat = 10
  static let cornerRadius: CGFloat = 12
}
