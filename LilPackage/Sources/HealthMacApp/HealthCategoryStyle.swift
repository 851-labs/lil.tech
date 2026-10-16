public import HealthCatalog
public import SwiftUI

/// A data type's name with its category's icon, in the category's color.
struct HealthTypeLabel: View {
  let type: HealthDataType

  var body: some View {
    Label(type.name, systemImage: type.category?.symbolName ?? "circle")
      .foregroundStyle(type.category?.color ?? .secondary)
  }
}

extension HealthCategory {
  /// The category's color in iPad Health, used for its icon.
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
