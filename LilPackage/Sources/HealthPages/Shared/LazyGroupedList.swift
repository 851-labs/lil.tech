import SwiftUI

// iOS's grouped list (`List` with `.listStyle(.insetGrouped)`) for the Mac, which has none, for
// lists too long to be a `Form`: All Data and Food (851-3005), and the record lists (workouts,
// ECGs, audiograms, beat-to-beat measurements, Health Documents, State of Mind and assessments,
// 851-3032), which hold 500 to 2,000 records at most. A grouped `Form` builds every row at once on
// macOS, however few are on screen (851-2820): 1,000 rows took 3.9 s and 10,000 took 51 s on
// macOS 27, and 100,000 crashed it. This draws what it draws, from a `LazyVStack`, so only the
// rows on screen are built: its background and its sections' fill (`.background` and
// `.background.secondary`, the colors it paints), its width and insets, its bold section headers,
// and its rows' insets and separators. A `.listStyle` of our own isn't possible: `ListStyle`'s
// requirements aren't public.
//
// It reads plain `Section`s, as `List` does, with `Group(sections:)` (851-3056). That stays lazy:
// in an 800 x 600 window, one section of 2,000 rows or 20 of 100 built 12 rows, as hand-built
// sections did, and one section of 100,000 first appeared as fast as one of 1,000.

/// A lazily built list in a grouped form's look, made of `Section`s as a `List` is:
///
/// ```swift
/// LazyGroupedList {
///   ForEach(months, id: \.start) { month in
///     Section(title(month.start)) {
///       ForEach(month.records) { record in
///         NavigationLink { RecordDetail(record) } label: { RecordRow(record) }
///       }
///     }
///   }
/// }
/// ```
///
/// Each section is its header, when it has one, in bold, then its rows on the section's fill,
/// rounded at its top and bottom, then its footer, when it has one, in secondary text. A row that's
/// a button, as a `NavigationLink` is, is a navigation row: it ends in a chevron, and opens from
/// anywhere on it. Other rows (a chart, a log) have no chevron.
struct LazyGroupedList<Content: View>: View {
  let paging: Paging?
  @ViewBuilder let content: Content

  /// A list loaded whole.
  init(@ViewBuilder content: () -> Content) {
    self.paging = nil
    self.content = content()
  }

  /// A list that loads a page at a time: while `hasMore`, it calls `loadMore` when its end comes
  /// into view, and its last section stays open, since the next page may continue it (851-3040).
  /// Once loading more failed (`moreFailed`), it ends in a button to try again.
  init(
    hasMore: Bool, moreFailed: Bool, loadMore: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.paging = Paging(hasMore: hasMore, moreFailed: moreFailed, loadMore: loadMore)
    self.content = content()
  }

  struct Paging {
    let hasMore: Bool
    let moreFailed: Bool
    let loadMore: () -> Void

    /// Whether the last section may go on in the next page.
    var isOpen: Bool { hasMore && !moreFailed }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        Group(sections: content) { sections in
          ForEach(sections) { section in
            LazyGroupedListSection(
              section: section, isFirst: section.id == sections.first?.id,
              isOpen: paging?.isOpen == true && section.id == sections.last?.id)
          }
        }
        if let paging {
          Group {
            if paging.moreFailed {
              Button("Couldn't load more. Try Again", action: paging.loadMore)
            } else if paging.hasMore {
              // Loads the next page when the end of the list comes into view.
              ProgressView()
                .onAppear(perform: paging.loadMore)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 12)
        }
      }
      .padding(LazyGroupedListMetrics.pageInset)
      .frame(maxWidth: LazyGroupedListMetrics.sectionWidth + 2 * LazyGroupedListMetrics.pageInset)
      .frame(maxWidth: .infinity)
    }
    .background(.background)
  }
}

/// A section: its header, its rows, the section's corners on the first and the last, and its
/// footer.
private struct LazyGroupedListSection: View {
  let section: SectionConfiguration
  /// Whether the section is the list's first, with no section above it to keep clear of.
  let isFirst: Bool
  /// Whether the section may go on in the next page, so its last loaded row stays open, with no
  /// bottom corners, while that loads (851-3040).
  let isOpen: Bool

  var body: some View {
    let rows = section.content
    if !section.header.isEmpty {
      section.header
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, LazyGroupedListMetrics.rowInset)
        .padding(.top, isFirst ? 0 : 30)
        .padding(.bottom, 10)
    }
    ForEach(rows) { row in
      LazyGroupedListRow(
        isFirst: row.id == rows.first?.id, isLast: !isOpen && row.id == rows.last?.id
      ) {
        row
      }
    }
    if !section.footer.isEmpty {
      section.footer
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, LazyGroupedListMetrics.rowInset)
        .padding(.top, 6)
    }
  }
}

/// A row of a section, as a grouped form's: its content, on the section's fill, rounded at the
/// section's top and bottom, with a separator above it unless it's the first.
private struct LazyGroupedListRow<Content: View>: View {
  let isFirst: Bool
  /// False for the last row loaded while its section may go on in the next page, so the section
  /// stays open.
  let isLast: Bool
  @ViewBuilder let content: Content

  var body: some View {
    let radius = LazyGroupedListMetrics.cornerRadius
    VStack(spacing: 0) {
      if !isFirst {
        // Half a `Divider`'s strength, as light as a grouped form's separators.
        Divider()
          .opacity(0.5)
          .padding(.horizontal, LazyGroupedListMetrics.rowInset)
      }
      content
        .padding(.horizontal, LazyGroupedListMetrics.rowInset)
        .padding(.vertical, LazyGroupedListMetrics.rowVerticalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(
      .background.secondary,
      in: UnevenRoundedRectangle(
        topLeadingRadius: isFirst ? radius : 0, bottomLeadingRadius: isLast ? radius : 0,
        bottomTrailingRadius: isLast ? radius : 0, topTrailingRadius: isFirst ? radius : 0,
        style: .continuous)
    )
    // It styles every button in the row, so a row that isn't a button shouldn't hold one: it would
    // get a chevron.
    .buttonStyle(NavigationRowStyle())
  }
}

/// A row that's a button (a `NavigationLink`): plain, ending in a chevron, and pressed from
/// anywhere on the row, its insets included: the button takes the row's insets, then gives them
/// back, so the row's own (`LazyGroupedListRow`, the same metrics) put its content where any other
/// row's is. The pages a link opens don't inherit the style.
private struct NavigationRowStyle: PrimitiveButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button(action: configuration.trigger) {
      HStack(spacing: 10) {
        configuration.label
        Image(systemName: "chevron.right")
          .font(.caption.bold())
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // Over the row's insets too, as the row's own shape.
      .padding(.horizontal, LazyGroupedListMetrics.rowInset)
      .padding(.vertical, LazyGroupedListMetrics.rowVerticalInset)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Back within the insets, which the row adds.
    .padding(.horizontal, -LazyGroupedListMetrics.rowInset)
    .padding(.vertical, -LazyGroupedListMetrics.rowVerticalInset)
  }
}

/// A grouped form's measurements on macOS 27.
private enum LazyGroupedListMetrics {
  /// Between the page's edges and its sections.
  static let pageInset: CGFloat = 20
  /// A section's width at most.
  static let sectionWidth: CGFloat = 700
  /// Between a section's edges and its rows' content, and its separators.
  static let rowInset: CGFloat = 10
  /// Between a row's edges and its content, above and below.
  static let rowVerticalInset: CGFloat = 8
  static let cornerRadius: CGFloat = 12
}
