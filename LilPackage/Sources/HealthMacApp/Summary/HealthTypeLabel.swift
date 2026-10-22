import HealthCatalog
import HealthUI
import SwiftUI

/// A data type's name with its category's icon, in the category's color unless given another.
struct HealthTypeLabel: View {
  let type: HealthDataType
  var color: Color?

  var body: some View {
    Label(type.name, systemImage: type.category?.symbolName ?? "circle")
      .foregroundStyle(color ?? Self.color(of: type))
  }

  /// A type's own color: its category's.
  static func color(of type: HealthDataType) -> Color {
    type.category?.color ?? .secondary
  }
}
