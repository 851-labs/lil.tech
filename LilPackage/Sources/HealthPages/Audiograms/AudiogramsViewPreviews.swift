import HealthDatabase
import HealthUI
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: made-up audiograms.

private let now = Date(timeIntervalSince1970: 1_760_400_000)

/// An audiogram with each ear's dBHL at 250 Hz to 8 kHz.
private func audiogram(
  _ index: Int, left: [Double]?, right: [Double]?, daysAgo: Double
) -> HealthAudiogram {
  let frequencies: [Double] = [250, 500, 1_000, 2_000, 3_000, 4_000, 6_000, 8_000]
  let points = frequencies.enumerated().map { offset, frequency in
    var tests: [String] = []
    if let left {
      tests.append(
        #"{"side":0,"type":0,"masked":false,"sensitivity":\#(left[offset]),"clampingLower":null,"clampingUpper":null}"#
      )
    }
    if let right {
      tests.append(
        #"{"side":1,"type":0,"masked":false,"sensitivity":\#(right[offset]),"clampingLower":null,"clampingUpper":null}"#
      )
    }
    return #"{"frequency":\#(frequency),"tests":[\#(tests.joined(separator: ","))]}"#
  }
  let start = Int(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000)
  return HealthAudiogram(
    id: "6f1c2a40-0000-4000-8000-\(String(format: "%012d", index))", startDate: start,
    endDate: start + 600_000, points: "[\(points.joined(separator: ","))]",
    sourceName: "AirPods Pro", sourceBundleID: "com.apple.HearingTest")
}

private let typical = audiogram(
  1, left: [10, 10, 15, 15, 20, 25, 30, 35], right: [5, 10, 10, 15, 25, 30, 40, 45], daysAgo: 3)
private let moderate = audiogram(
  2, left: [25, 30, 40, 50, 55, 60, 65, 70], right: [20, 25, 35, 45, 55, 60, 70, 75], daysAgo: 200)
private let oneEar = audiogram(3, left: nil, right: [15, 15, 20, 20, 25, 35, 40, 50], daysAgo: 420)

@MainActor
private func list(_ state: AudiogramsContent.State, limit: Int = RecentAudiograms.limit)
  -> some View
{
  NavigationStack {
    AudiogramsContent(state: state, limit: limit)
  }
  .previewFrame(width: 620, height: 480)
}

@MainActor
private func detail(_ audiogram: HealthAudiogram) -> some View {
  preparePreviewDatabase()
  return NavigationStack {
    AudiogramDetailView(audiogram: audiogram)
  }
  .previewFrame(width: 760, height: 660)
}

#Preview("Audiograms") {
  list(.loaded([typical, moderate, oneEar]))
}

#Preview("Audiograms, at the limit") {
  list(.loaded([typical, moderate, oneEar]), limit: 3)
}

#Preview("No audiograms") {
  list(.loaded([]))
}

#Preview("Audiograms loading") {
  list(.loading)
}

#Preview("Audiograms failed") {
  list(.failed("The database couldn't be read."))
}

#Preview("Little to no hearing loss") {
  detail(typical)
}

#Preview("Moderate hearing loss") {
  detail(moderate)
}

#Preview("One ear tested") {
  detail(oneEar)
}

#Preview("No response at 8 kHz, extended frequencies") {
  // The right ear's 8 kHz result is a bound, and 12.5 kHz is past the usual range.
  let points = #"""
    [{"frequency":1000,"tests":[{"side":0,"type":0,"masked":false,"sensitivity":15,"clampingLower":null,"clampingUpper":null},{"side":1,"type":0,"masked":false,"sensitivity":20,"clampingLower":null,"clampingUpper":null}]},
     {"frequency":4000,"tests":[{"side":0,"type":0,"masked":false,"sensitivity":35,"clampingLower":null,"clampingUpper":null},{"side":1,"type":0,"masked":false,"sensitivity":55,"clampingLower":null,"clampingUpper":null}]},
     {"frequency":8000,"tests":[{"side":0,"type":0,"masked":false,"sensitivity":60,"clampingLower":null,"clampingUpper":null},{"side":1,"type":0,"masked":false,"sensitivity":90,"clampingLower":90,"clampingUpper":null}]},
     {"frequency":12500,"tests":[{"side":0,"type":0,"masked":false,"sensitivity":75,"clampingLower":null,"clampingUpper":null}]}]
    """#
  return detail(
    HealthAudiogram(
      id: "6f1c2a40-0000-4000-8000-000000000008", startDate: 1_760_100_000_000,
      endDate: 1_760_100_600_000, points: points, sourceName: "Hearing Test App",
      sourceBundleID: "com.example.hearing"))
}

#Preview("No frequencies tested") {
  detail(
    HealthAudiogram(
      id: "6f1c2a40-0000-4000-8000-000000000009", startDate: 1_760_000_000_000,
      endDate: 1_760_000_600_000, points: "[]", sourceName: "AirPods Pro",
      sourceBundleID: "com.apple.HearingTest"))
}
