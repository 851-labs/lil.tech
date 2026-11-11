#if os(iOS) && DEBUG
  @testable import HealthPhoneApp
  import HealthUpload
  import SwiftUI
  import Testing

  // Diagnostics (`DiagnosticsView`), from Settings in Debug builds only (851-4173, 851-4190):
  // before anything runs, while each check runs, their numbers, and their failures. Synthetic
  // numbers only.

  extension PhoneSnapshotTests {
    @Test(arguments: diagnosticsCatalog.selectedStates)
    func diagnostics(_ state: CatalogState) {
      state.assertPhoneSnapshots()
    }
  }

  let diagnosticsCatalog = StateCatalog(
    phone: "Diagnostics",
    states: [
      CatalogState("Not run") {
        diagnostics(DiagnosticsModel())
      },
      CatalogState("Running") {
        diagnostics(
          DiagnosticsModel(
            series: .counting(done: 37, of: 112), links: .checking, watch: .watching,
            arrivals: [.init(id: 1, kind: .workout)]))
      },
      CatalogState("Series counted") {
        diagnostics(DiagnosticsModel(series: .counted(SyntheticDiagnostics.series)))
      },
      // Each section's results alone, which a phone's screen can't show together.
      CatalogState("Links checked") {
        diagnostics(DiagnosticsModel(links: SyntheticDiagnostics.links))
      },
      CatalogState("Arrivals") {
        diagnostics(DiagnosticsModel(watch: .watching, arrivals: SyntheticDiagnostics.arrivals))
      },
      CatalogState("Failed") {
        diagnostics(
          DiagnosticsModel(
            series: .failed("Protected health data is inaccessible"),
            links: .failed("Protected health data is inaccessible"),
            watch: .failed("Protected health data is inaccessible")))
      },
    ])

  @MainActor
  private func diagnostics(_ model: DiagnosticsModel) -> some View {
    NavigationStack { DiagnosticsView(model: model) }
  }

  /// Made-up numbers, about what a year of an iPhone and a Watch might hold.
  private enum SyntheticDiagnostics {
    static let series: [HealthDiagnostics.SeriesCount] = [
      .init(
        type: "HKQuantityTypeIdentifierHeartRate", samples: 412_806, series: 1_204,
        values: 286_310, largest: 4_312),
      .init(
        type: "HKQuantityTypeIdentifierStepCount", samples: 98_114, series: 3_871, values: 41_265,
        largest: 120),
      .init(
        type: "HKQuantityTypeIdentifierActiveEnergyBurned", samples: 503_377, series: 0,
        values: 0, largest: 0),
      .init(
        type: "HKQuantityTypeIdentifierDistanceWalkingRunning", samples: 120_442, series: 212,
        values: 9_874, largest: 1_046),
      .init(
        type: "HKQuantityTypeIdentifierRestingHeartRate", samples: 365, series: 0, values: 0,
        largest: 0),
      .init(
        type: "HKQuantityTypeIdentifierBodyMass", samples: 0, series: 0, values: 0, largest: 0),
    ]

    static let links = DiagnosticsModel.LinksPhase.checked(
      workouts: .init(checked: 41, withLinks: 39, withLateLinks: 3, linked: 61_220, late: 418),
      electrocardiograms: .init(checked: 2, withLinks: 2, withLateLinks: 0, linked: 3, late: 0))

    static let arrivals: [DiagnosticsModel.Arrival] = [
      .init(
        id: 1, kind: .workout, atArrival: 0, latest: 1_812, counted: .seconds(300),
        lastChanged: .seconds(30), isDone: true),
      .init(id: 2, kind: .electrocardiogram, atArrival: 2, latest: 2, counted: .seconds(60)),
      .init(id: 3, kind: .workout, atArrival: 640, latest: 640, failed: true),
    ]
  }
#endif
