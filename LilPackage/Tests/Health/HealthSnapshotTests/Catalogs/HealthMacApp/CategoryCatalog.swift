#if os(macOS)
  import HealthCatalog
  import HealthDatabase
  @testable import HealthMacApp
  import SQLiteData
  import SwiftUI
  import Testing

  // A Browse category (`MetricsView`), a grouped form: its metrics' rows from the catalog
  // database at `previewNow`, then those without data. Synthetic data only. The old preview
  // "Heart, dark" is "Heart"'s dark reference.

  extension MacSnapshotTests {
    @Test(arguments: categoryCatalog.selectedStates)
    func category(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let categoryCatalog = StateCatalog(
    "Category", width: 760, minHeight: 480,
    states: [
      // Some metrics have data, the rest are under No Data Available.
      CatalogState("Heart") { metrics(.heart) },
      CatalogState("Activity") { metrics(.activity) },
      CatalogState("Respiratory") { metrics(.respiratory) },
      // Every row's sparkline in its type's chart style (851-3101): Activity's bars, Heart's
      // ranges, dots and lines, Body Measurements' lines and Mobility's dots.
      CatalogState("Body Measurements") { metrics(.bodyMeasurements) },
      CatalogState("Mobility") { metrics(.mobility) },
      // In the US's units (851-3116): pounds, feet and inches, inches and °F; mph, inches and
      // yards.
      CatalogState("Body Measurements, US", locale: Locale(identifier: "en_US")) {
        metrics(.bodyMeasurements)
      },
      CatalogState("Mobility, US", locale: Locale(identifier: "en_US")) { metrics(.mobility) },
      // A week with few readings: one heart rate a day, so each range is a dot, and a single
      // resting heart rate, a line's one point.
      CatalogState("Heart, a few readings") { metrics(.heart, .loaded(fewReadings())) },
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
      // Sound levels show their week's exposure in place of a value (851-3100): within the
      // limit in the catalog database, a minute every 2 hours, none over 85 dB.
      CatalogState("Hearing") { metrics(.hearing) },
      // Headphones over it, the environment within it.
      CatalogState("Hearing, over the limit") {
        metrics(
          .hearing,
          .loaded(
            summaries(.hearing).map {
              var summary = $0
              if summary.id == "HKQuantityTypeIdentifierHeadphoneAudioExposure" {
                summary.soundExposure = SoundExposure(dose: 1.6)
              }
              return summary
            }))
      },
      CatalogState("Hearing, no data") {
        metrics(
          .hearing, .loaded(HealthCatalog.types(in: .hearing).map { MetricSummary(id: $0.id) }))
      },
      CatalogState("Hearing, loading") { metrics(.hearing, .loading) },
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

  /// The app's request, at the suite's date and calendar.
  private func summaries(_ category: HealthCategory) -> [MetricSummary] {
    try! catalogDatabase.read { db in try CategorySummaries(category: category).fetch(db) }
  }

  /// Heart's types with a few days of readings in the week before `previewNow`, the rest
  /// without data.
  private func fewReadings() -> [MetricSummary] {
    let calendar = previewCalendar
    let today = calendar.startOfDay(for: previewNow)
    func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    let latest = calendar.date(byAdding: .hour, value: 8, to: today)!
    let summaries = [
      MetricSummary(
        id: "HKQuantityTypeIdentifierHeartRate", latestDate: latest, latestValue: 64,
        unit: "count/min",
        days: [(-5, 71.0), (-3, 58), (-2, 66), (0, 64)].map { offset, value in
          DailyValue(day: day(offset), value: value, minimum: value, maximum: value)
        }),
      MetricSummary(
        id: "HKQuantityTypeIdentifierRestingHeartRate", latestDate: latest, latestValue: 57,
        unit: "count/min", days: [DailyValue(day: day(0), value: 57, minimum: 57, maximum: 57)]),
      MetricSummary(
        id: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", latestDate: latest,
        latestValue: 48, unit: "ms",
        days: [(-6, 41.0), (-1, 52), (0, 48)].map { offset, value in
          DailyValue(day: day(offset), value: value, minimum: value - 6, maximum: value + 9)
        }),
    ]
    return HealthCatalog.types(in: .heart).map { type in
      summaries.first { $0.id == type.id } ?? MetricSummary(id: type.id)
    }
  }
#endif
