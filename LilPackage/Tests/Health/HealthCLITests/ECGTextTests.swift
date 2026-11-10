import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health ecgs` and `ecg`'s text (851-4159): each recording's classification, heart rate and
// symptoms, and a page of voltages a line a second. Synthetic data only.
@Suite struct ECGTextTests {
  @Test func listsEachRecording() {
    let result = HealthElectrocardiogramsResult(
      timeZone: "UTC", range: "W", start: "2026-10-14T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 3,
      recordings: [
        HealthElectrocardiogramItem(
          id: "e1", start: "2026-10-19T08:30:00+00:00", end: "2026-10-19T08:30:30+00:00",
          duration: 30, classification: "Sinus Rhythm", averageHeartRate: 67.6,
          samplingFrequency: 512, voltageCount: 15_360, symptoms: "No Symptoms",
          algorithmVersion: 2, source: "ECG"),
        HealthElectrocardiogramItem(
          id: "e2", start: "2026-10-17T06:00:00+00:00", end: "2026-10-17T06:00:30+00:00",
          duration: 30, classification: "Inconclusive", averageHeartRate: nil,
          samplingFrequency: nil, voltageCount: 0, symptoms: "Not Logged", source: "ECG"),
      ])
    #expect(
      result.text == """
        ECGs, W: 2026-10-14 to 2026-10-20 (UTC)
        3 recordings

          2026-10-19 08:30   Sinus Rhythm · 68 BPM average · No Symptoms · ECG   e1
          2026-10-17 06:00   Inconclusive · Not Logged · ECG   e2

        Showing the 2 most recent recordings.

        """)
  }

  @Test func listsAPageOfVoltagesASecondALine() {
    let result = HealthElectrocardiogramVoltagesResult(
      timeZone: "UTC", id: "e1", start: "2026-10-19T08:30:00+00:00", samplingFrequency: 6,
      voltageCount: 30, offset: 2, rate: 3, measurementsPerValue: 2,
      values: [1.5, nil, -20, 1000.25, 0], nextCursor: "27")
    #expect(
      result.text == """
        ECG e1   2026-10-19 08:30 (UTC)
        30 measurements at 6 Hz. This page: 5 values at 3 Hz from 2 s, each the average of 2, in µV:
          2 s   1.5 – -20
          3 s   1000.25 0

        More: --cursor 27

        """)
  }
}
