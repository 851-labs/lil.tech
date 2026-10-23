#if os(macOS)
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // ECGs (`ElectrocardiogramsContent`) and an ECG (`ElectrocardiogramDetailContent`): made-up
  // recordings before `previewNow`, and traces from `HealthDatabase.syntheticElectrocardiogram`.
  // Synthetic data only.

  extension MacSnapshotTests {
    @Test(arguments: electrocardiogramsCatalog.selectedStates)
    func electrocardiograms(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let electrocardiogramsCatalog = StateCatalog(
    "Electrocardiograms", width: 620, minHeight: 560,
    states: [
      CatalogState("ECGs") { list(.loaded(recordings)) },
      // As if these were the most it holds: it says the list is cut short.
      CatalogState("ECGs, at the limit") { list(.loaded(recordings), limit: recordings.count) },
      CatalogState("No ECGs") { list(.loaded([])) },
      CatalogState("ECGs loading") { list(.loading) },
      CatalogState("ECGs failed") { list(.failed("The database couldn't be read.")) },
      // An ECG.
      CatalogState("Sinus rhythm", width: 860) {
        detail(recordings[0], .loaded(HealthDatabase.syntheticElectrocardiogram()))
      },
      CatalogState("Atrial fibrillation, symptoms", width: 860) {
        detail(
          recordings[1], .loaded(HealthDatabase.syntheticElectrocardiogram(beatsPerMinute: 104)))
      },
      // Stretches without a value, as when the finger leaves the crown.
      CatalogState("Poor recording, with gaps", width: 860) {
        let trace = HealthDatabase.syntheticElectrocardiogram().enumerated().map { index, value in
          (4_000..<5_500).contains(index) || (11_000..<11_600).contains(index) ? Float.nan : value
        }
        detail(recordings[3], .loaded(trace))
      },
      CatalogState("Tall waves, narrow window", width: 520) {
        detail(recordings[0], .loaded(HealthDatabase.syntheticElectrocardiogram().map { $0 * 2.4 }))
      },
      CatalogState("Recording loading", width: 860) {
        detail(recordings[0], .loading)
      },
      CatalogState("No recording", width: 860) { detail(recordings[4], .none) },
      CatalogState("Recording failed", width: 860) {
        detail(recordings[0], .failed("The recording couldn't be downloaded."))
      },
    ],
    // The trace's paper keeps its place and height, loading or not, so the details below stay put
    // (851-3091).
    sameLayout: [
      ["Sinus rhythm", "Recording loading", "Recording failed", "Atrial fibrillation, symptoms"]
    ])

  private func recording(
    _ index: Int, classification: Int, bpm: Double? = 68, symptoms: Int = 1, daysAgo: Double
  ) -> HealthElectrocardiogram {
    let start = previewNow.addingTimeInterval(-daysAgo * 86_400).unixMilliseconds
    return HealthElectrocardiogram(
      id: "6f1c2a40-0000-4000-8000-\(String(format: "%012d", index))", startDate: start,
      endDate: start + 30_000, classification: classification, symptomsStatus: symptoms,
      averageHeartRate: bpm, samplingFrequency: 512, voltageCount: 15_360, voltages: "preview",
      sourceName: "Apple Watch", sourceBundleID: "com.apple.NanoHeartRhythm")
  }

  private let recordings = [
    recording(1, classification: 1, daysAgo: 1),
    recording(2, classification: 2, bpm: 104, symptoms: 2, daysAgo: 6),
    recording(3, classification: 3, bpm: 47, daysAgo: 12),
    recording(4, classification: 5, bpm: nil, symptoms: 0, daysAgo: 34),
    recording(5, classification: 1, bpm: 72, daysAgo: 40),
    recording(6, classification: 6, bpm: 88, daysAgo: 70),
  ]

  @MainActor
  private func list(
    _ state: ElectrocardiogramsContent.State, limit: Int = RecentElectrocardiograms.limit
  ) -> some View {
    NavigationStack {
      ElectrocardiogramsContent(state: state, limit: limit)
    }
  }

  @MainActor
  private func detail(
    _ recording: HealthElectrocardiogram, _ trace: ElectrocardiogramDetailContent.Trace
  ) -> some View {
    NavigationStack {
      ElectrocardiogramDetailContent(recording: recording, trace: trace)
    }
  }
#endif
