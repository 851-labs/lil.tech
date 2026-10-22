import HealthCatalog
import HealthUI
import SwiftUI

/// A data type's name with its icon, in its color unless given another.
struct HealthTypeLabel: View {
  let type: HealthDataType
  var color: Color?

  var body: some View {
    Label(type.name, systemImage: type.symbolName)
      .foregroundStyle(color ?? type.color)
  }
}
