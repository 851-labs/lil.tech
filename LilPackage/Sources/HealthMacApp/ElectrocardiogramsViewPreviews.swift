import HealthDatabase
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: made-up recordings and traces from
// `HealthDatabase.syntheticElectrocardiogram`.

private let now = Date(timeIntervalSince1970: 1_760_400_000)

private func recording(
  _ index: Int, classification: Int, bpm: Double? = 68, symptoms: Int = 1, daysAgo: Double
) -> HealthElectrocardiogram {
  let start = Int(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000)
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
  .frame(width: 620, height: 560)
}

@MainActor
private func detail(
  _ recording: HealthElectrocardiogram, _ trace: ElectrocardiogramDetailContent.Trace
) -> some View {
  NavigationStack {
    ElectrocardiogramDetailContent(recording: recording, trace: trace)
  }
  .frame(width: 860, height: 640)
}

#Preview("ECGs") {
  list(.loaded(recordings))
}

#Preview("ECGs, at the limit") {
  // As if these were the most it holds: it says the list is cut short.
  list(.loaded(recordings), limit: recordings.count)
}

#Preview("No ECGs") {
  list(.loaded([]))
}

#Preview("ECGs loading") {
  list(.loading)
}

#Preview("ECGs failed") {
  list(.failed("The database couldn't be read."))
}

#Preview("Sinus rhythm") {
  detail(recordings[0], .loaded(HealthDatabase.syntheticElectrocardiogram()))
}

#Preview("Atrial fibrillation, symptoms") {
  detail(
    recordings[1], .loaded(HealthDatabase.syntheticElectrocardiogram(beatsPerMinute: 104)))
}

#Preview("Poor recording, with gaps") {
  // Stretches without a value, as when the finger leaves the crown.
  let trace = HealthDatabase.syntheticElectrocardiogram().enumerated().map { index, value in
    (4_000..<5_500).contains(index) || (11_000..<11_600).contains(index) ? Float.nan : value
  }
  return detail(recordings[3], .loaded(trace))
}

#Preview("Tall waves, narrow window") {
  let tall = HealthDatabase.syntheticElectrocardiogram().map { $0 * 2.4 }
  return NavigationStack {
    ElectrocardiogramDetailContent(recording: recordings[0], trace: .loaded(tall))
  }
  .frame(width: 520, height: 640)
}

#Preview("Recording loading") {
  detail(recordings[0], .loading)
}

#Preview("No recording") {
  detail(recordings[4], .none)
}

#Preview("Recording failed") {
  detail(recordings[0], .failed("The recording couldn't be downloaded."))
}
