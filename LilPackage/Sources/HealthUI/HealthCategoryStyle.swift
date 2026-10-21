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

/// A category's name with its icon in its color, as in Health's lists, and white on a selected
/// sidebar row (`TintedIcon`).
public struct HealthCategoryLabel: View {
  let category: HealthCategory

  public init(_ category: HealthCategory) {
    self.category = category
  }

  public var body: some View {
    Label {
      Text(category.name)
    } icon: {
      TintedIcon(category.symbolName, color: category.color)
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
