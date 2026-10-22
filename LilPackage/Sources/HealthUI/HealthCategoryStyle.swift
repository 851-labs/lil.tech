// How Health categories look in lil health's apps, shared by the Mac and the iPhone. Apart from
// HealthCatalog, which stays free of UI frameworks.
public import HealthCatalog
public import SwiftUI

extension HealthCategory {
  /// The category's color in Health, for its icon.
  public var color: Color {
    switch self {
    case .activity: .orange
    case .bodyMeasurements: .purple
    case .cycleTracking: .pink
    case .hearing: .blue
    case .heart: .red
    case .medications: .teal
    case .mentalWellbeing: .cyan
    case .mobility: .orange
    case .nutrition: .green
    case .respiratory: .cyan
    case .sleep: .mint
    case .symptoms: .indigo
    case .vitals: .red
    case .otherData: .blue
    }
  }
}

extension HealthDataType {
  /// The type's color, for its icon and charts: its category's.
  public var color: Color { category?.color ?? Self.uncategorizedColor }

  /// The color of a type without a category: the characteristics, which Health shows in Health
  /// Details, whose icon is in the accent color. Unlike gray, it stands out in charts, next to a
  /// highlight's gray earlier week and through the opacity of bars and fills.
  public static let uncategorizedColor = Color.accentColor
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
      // Two-tone symbols (Summary, Health Details, Medications) go wholly white too.
      .symbolRenderingMode(isProminent ? .monochrome : nil)
      .foregroundStyle(isProminent ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
  }
}
