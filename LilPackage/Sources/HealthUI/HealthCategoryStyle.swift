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

/// A category's name with its icon in its color, as in Health's lists.
public struct HealthCategoryLabel: View {
  let category: HealthCategory

  public init(_ category: HealthCategory) {
    self.category = category
  }

  public var body: some View {
    Label {
      Text(category.name)
    } icon: {
      Image(systemName: category.symbolName)
        .foregroundStyle(category.color)
    }
  }
}
