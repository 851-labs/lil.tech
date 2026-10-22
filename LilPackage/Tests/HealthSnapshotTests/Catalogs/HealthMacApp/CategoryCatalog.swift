#if os(macOS)
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import SQLiteData
  import SwiftUI
  import Testing

  // A Browse category (`MetricsView`): its metrics' cards from the catalog database at
  // `previewNow`, then those without data. Synthetic data only. Its previews' "Heart, dark" is
  // "Heart"'s dark reference.

  extension MacSnapshotTests {
    @Test(arguments: categoryCatalog.selectedStates)
    func category(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let categoryCatalog = StateCatalog(
    "Category", width: 760, minHeight: 720,
    states: [
      // Some metrics have data, the rest are under No Data Available.
      CatalogState("Heart") { metrics(.heart) },
      CatalogState("Activity") { metrics(.activity) },
      CatalogState("Respiratory") { metrics(.respiratory) },
      CatalogState("Medications") { metrics(.medications) },
      // Shared medications without doses yet: Medications has data, without a date.
      CatalogState("Medications, none logged") {
        metrics(
          .medications,
          .loaded([
            MetricSummary(id: "HKDataTypeUserAnnotatedMedicationConcept", hasUndatedData: true),
            MetricSummary(id: "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"),
          ]))
      },
      CatalogState("No data") {
        metrics(
          .mobility, .loaded(HealthCatalog.types(in: .mobility).map { MetricSummary(id: $0.id) }))
      },
      CatalogState("Loading") { metrics(.heart, .loading) },
      CatalogState("Failed") { metrics(.heart, .failed("The database couldn't be read.")) },
    ])

  /// A category in a navigation stack, for its title: its summaries from the catalog database,
  /// unless given a state.
  @MainActor
  private func metrics(_ category: HealthCategory, _ state: MetricsView.State? = nil) -> some View {
    NavigationStack {
      MetricsView(category: category, state: state ?? .loaded(summaries(category)))
    }
  }

  private func summaries(_ category: HealthCategory) -> [MetricSummary] {
    try! catalogDatabase.read { db in
      try HealthDatabase.metricSummaries(
        in: category, now: previewNow, calendar: previewCalendar, db)
    }
  }
#endif
