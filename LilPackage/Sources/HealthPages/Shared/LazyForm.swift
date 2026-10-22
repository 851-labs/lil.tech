import SwiftUI

// A grouped form's look for lists too long to be a `Form`: All Data and Food (851-3005). A grouped
// `Form` builds every row at once on macOS, however few are on screen (851-2820): 1,000 rows took
// 3.9 s and 10,000 took 51 s on macOS 27, and 100,000 crashed it. These draw what it draws, from
// a `LazyVStack`, so only the rows on screen are built: its background and its sections' fill
// (`.background` and `.background.secondary`, the colors it paints), its width and insets, its
// bold section headers, and its rows' insets and separators.

/// A lazily built page in a grouped form's look. Its content is `LazyFormHeader`s and
/// `LazyFormRow`s, one after another.
struct LazyForm<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, LazyFormMetrics.pageInset)
      .padding(.top, 20)
      .padding(.bottom, LazyFormMetrics.pageInset)
      .frame(maxWidth: LazyFormMetrics.maxWidth)
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

/// A row of a section, as a grouped form's: on the section's fill, rounded at the section's top
/// and bottom, with a separator above it unless it's the first.
struct LazyFormRow<Content: View>: View {
  let isFirst: Bool
  /// False for the last row loaded while its section may go on in the next page, so the section
  /// stays open.
  let isLast: Bool
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
      content
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

/// A navigation row's chevron, as a grouped form's `NavigationLink` draws it.
struct LazyFormChevron: View {
  var body: some View {
    Image(systemName: "chevron.right")
      .font(.caption.bold())
      .foregroundStyle(.tertiary)
  }
}

/// A grouped form's measurements on macOS 27.
private enum LazyFormMetrics {
  /// Between the page's edges and its sections.
  static let pageInset: CGFloat = 20
  /// A section's width, 700, and the page's insets.
  static let maxWidth: CGFloat = 740
  /// Between a section's edges and its rows' content, and its separators.
  static let rowInset: CGFloat = 10
  static let cornerRadius: CGFloat = 12
}
