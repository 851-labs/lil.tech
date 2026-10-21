public import SwiftUI

/// A row in a card of links to other pages (Show All Data, Data Sources): its title and a
/// chevron, the whole row clickable. The label of a plain-styled `NavigationLink`.
public struct PageLinkRow: View {
  let title: String

  public init(_ title: String) {
    self.title = title
  }

  public var body: some View {
    HStack {
      Text(title)
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.bold())
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}
