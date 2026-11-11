import HealthDatabase
import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health audiograms`' text (851-4161): each audiogram's ears, as the Audiogram page heads
// them, then each ear's charted result by frequency. Synthetic data only.
@Suite struct AudiogramTextTests {
  @Test func listsEachAudiogramAndEachEarsResults() {
    func test(
      _ sensitivity: Double, type: Int = 0, masked: Bool = false, lower: Double? = nil,
      upper: Double? = nil
    ) -> HealthAudiogramTest {
      HealthAudiogramTest(
        AudiogramTest(
          side: 0, type: type, masked: masked, sensitivity: sensitivity, clampingLower: lower,
          clampingUpper: upper))
    }
    let result = HealthAudiogramsResult(
      timeZone: "UTC", range: "Y", start: "2025-11-01T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 3,
      audiograms: [
        HealthAudiogramItem(
          id: "a1", start: "2026-10-19T08:00:00+00:00", end: "2026-10-19T08:06:00+00:00",
          leftEar: HealthAudiogramEar(18), rightEar: HealthAudiogramEar(38),
          points: [
            HealthAudiogramPoint(
              frequency: 500, left: [test(10, masked: true), test(5)], right: [test(30)]),
            HealthAudiogramPoint(
              frequency: 8000, left: [test(25.5, lower: 20, upper: 30)],
              right: [test(90, lower: 90)]),
          ],
          source: "Hearing Test"),
        HealthAudiogramItem(
          id: "a2", start: "2026-09-02T10:00:00+00:00", end: "2026-09-02T10:08:00+00:00",
          leftEar: HealthAudiogramEar(nil), rightEar: HealthAudiogramEar(98),
          points: [
            HealthAudiogramPoint(frequency: 1000, left: [], right: [test(98, type: 1, upper: 98)])
          ],
          source: "Test Audiometry App"),
      ])
    #expect(
      result.text == """
        Audiograms, Y: 2025-11-01 to 2026-10-20 (UTC)
        3 audiograms

          2026-10-19 08:00   Left Ear 18 dBHL (Little to No Hearing Loss) · Right Ear 38 dBHL (Mild Hearing Loss) · Hearing Test   a1
              Left   500 Hz 10 masked · 8000 Hz 25.5 (20 to 30)
              Right   500 Hz 30 · 8000 Hz ≥90
          2026-09-02 10:00   Left Ear Not Tested · Right Ear 98 dBHL (Profound Hearing Loss) · Test Audiometry App   a2
              Right   1000 Hz ≤98 (Unknown conduction)

        Showing the 2 most recent audiograms.

        """)
  }
}
