import HealthCatalog
import HealthDatabase
import HealthUI
import SQLiteData
import SwiftUI

// Synthetic data only (AGENTS.md): `makePreviewHealthDatabase()`.

@MainActor
private func metrics(_ category: HealthCategory, _ state: MetricsView.State) -> some View {
  NavigationStack {
    MetricsView(category: category, state: state)
  }
  .previewFrame(width: 760, height: 720)
}

@MainActor
private func previewSummaries(_ category: HealthCategory) -> [MetricSummary] {
  let database = makePreviewHealthDatabase()
  return
    (try? database.read { db in
      try HealthDatabase.metricSummaries(in: category, now: .now, calendar: .current, db)
    }) ?? []
}

#Preview("Heart") {
  // Some metrics have data, the rest are under No Data Available.
  metrics(.heart, .loaded(previewSummaries(.heart)))
}

#Preview("Activity") {
  metrics(.activity, .loaded(previewSummaries(.activity)))
}

#Preview("Respiratory") {
  metrics(.respiratory, .loaded(previewSummaries(.respiratory)))
}

#Preview("Medications") {
  metrics(.medications, .loaded(previewSummaries(.medications)))
}

#Preview("Medications, none logged") {
  // Shared medications without doses yet: Medications has data, without a date.
  metrics(
    .medications,
    .loaded([
      MetricSummary(id: "HKDataTypeUserAnnotatedMedicationConcept", hasUndatedData: true),
      MetricSummary(id: "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"),
    ]))
}

#Preview("No data") {
  metrics(.mobility, .loaded(HealthCatalog.types(in: .mobility).map { MetricSummary(id: $0.id) }))
}

#Preview("Heart, dark") {
  metrics(.heart, .loaded(previewSummaries(.heart)))
    .preferredColorScheme(.dark)
}

#Preview("Loading") {
  metrics(.heart, .loading)
}

#Preview("Failed") {
  metrics(.heart, .failed("The database couldn't be read."))
}
