public import SwiftUI

extension HealthCategory {
  /// The category's color in iPad Health, for its icon, on the Mac and the iPhone.
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
