import HealthCatalog
import SwiftUI

/// A data type's name with its category's icon, in the category's color.
struct HealthTypeLabel: View {
  let type: HealthDataType

  var body: some View {
    Label(type.name, systemImage: type.category?.symbolName ?? "circle")
      .foregroundStyle(type.category?.color ?? .secondary)
  }
}
