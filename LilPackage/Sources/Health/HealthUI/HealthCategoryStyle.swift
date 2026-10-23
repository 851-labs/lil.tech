// How Health categories look in lil health's apps, shared by the Mac and the iPhone. Apart from
// HealthCatalog, which stays free of UI frameworks.
public import HealthCatalog
public import SwiftUI

extension HealthCategory {
  /// The category's color in Health, for its icon: `colorName`'s.
  public var color: Color { Color(paletteName: colorName) }
}

extension Color {
  /// A card palette color by name (`CardColor`, `HealthCategory.colorName`): SwiftUI's system color
  /// of that name, the same on the Mac and the iPhone, light and dark. Gray for a name it doesn't
  /// know.
  public init(paletteName: String) {
    self =
      switch paletteName {
      case "red": .red
      case "orange": .orange
      case "yellow": .yellow
      case "green": .green
      case "mint": .mint
      case "teal": .teal
      case "cyan": .cyan
      case "blue": .blue
      case "indigo": .indigo
      case "purple": .purple
      case "pink": .pink
      case "brown": .brown
      default: .gray
      }
  }
}

extension HealthDataType {
  /// The type's color, for its icon and charts: its category's.
  public var color: Color { category?.color ?? Self.uncategorizedColor }

  /// The color of a type without a category: the characteristics. Unlike gray, it stands out in
  /// charts, next to a highlight's gray earlier week and through the opacity of bars and fills.
  public static let uncategorizedColor = Color.accentColor

  /// The SF Symbol shown with the type: its category's.
  public var symbolName: String { category?.symbolName ?? Self.uncategorizedSymbolName }

  /// The symbol of a type without a category: the characteristics, so a profile's, as Health
  /// Details has. Neither a question mark, which reads as an error, nor a plain circle.
  public static let uncategorizedSymbolName = "person.text.rectangle.fill"
}

/// A category's name with its icon in its color, as in Health's lists, and white on a selected
/// sidebar row (`TintedIcon`).
public struct HealthCategoryLabel: View {
  let category: HealthCategory

  public init(_ category: HealthCategory) {
    self.category = category
  }

  public var body: some View {
    TintedLabel(category.name, systemImage: category.symbolName, color: category.color)
  }
}

/// A title with a `TintedIcon`.
public struct TintedLabel: View {
  let title: String
  let systemImage: String
  let color: Color

  public init(_ title: String, systemImage: String, color: Color) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
  }

  public var body: some View {
    Label {
      Text(title)
    } icon: {
      TintedIcon(systemImage, color: color)
    }
  }
}

/// An icon in `color`, or all white with its text where the background is prominent: the
/// selected row of a sidebar in the key window, as in Mail or Finder (851-2823). On an inactive
/// window's gray selection it keeps its color.
public struct TintedIcon: View {
  let systemName: String
  let color: Color
  @Environment(\.backgroundProminence) private var prominence

  public init(_ systemName: String, color: Color) {
    self.systemName = systemName
    self.color = color
  }

  public var body: some View {
    let isProminent = prominence == .increased
    Image(systemName: systemName)
      // Two-tone symbols (Summary, Medications) go wholly white too.
      .symbolRenderingMode(isProminent ? .monochrome : nil)
      .foregroundStyle(isProminent ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
  }
}
