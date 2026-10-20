import HealthDatabase
import SwiftUI

// Synthetic data only (AGENTS.md): a made-up profile.

private let now = Date(timeIntervalSince1970: 1_760_400_000)

@MainActor
private func details(_ state: HealthDetailsContent.State) -> some View {
  // Its link to the vision prescriptions reads the database.
  preparePreviewDatabase()
  return NavigationStack {
    HealthDetailsContent(state: state, now: now)
  }
  .previewFrame(width: 620, height: 560)
}

#Preview("Health Details") {
  details(
    .loaded(
      HealthDetails(
        dateOfBirth: BirthDate(year: 1990, month: 4, day: 2), sex: .female, bloodType: .aPositive,
        skinType: .typeIII, wheelchairUse: .no, hasSynced: true)))
}

#Preview("Health Details, partly set") {
  details(
    .loaded(
      HealthDetails(
        dateOfBirth: BirthDate(year: 1984, month: 11, day: 23), bloodType: .oNegative,
        hasSynced: true)))
}

#Preview("Health Details, nothing synced") {
  details(.loaded(HealthDetails(characteristics: [])))
}

#Preview("Health Details loading") {
  details(.loading)
}

#Preview("Health Details failed") {
  details(.failed("The database couldn't be read."))
}
