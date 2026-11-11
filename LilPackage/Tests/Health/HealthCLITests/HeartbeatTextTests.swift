import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health heartbeats` and `heartbeat`'s text (851-4162): each series' average heart rate, HRV
// and beats, and a page of beats a line each. Synthetic data only.
@Suite struct HeartbeatTextTests {
  @Test func listsEachSeries() {
    let result = HealthHeartbeatSeriesResult(
      timeZone: "UTC", range: "W", start: "2026-10-14T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 3,
      series: [
        HealthHeartbeatSeriesItem(
          id: "h1", start: "2026-10-19T07:00:00+00:00", end: "2026-10-19T07:00:50+00:00",
          beatCount: 60, duration: 50.2037, gapCount: 0, intervalCount: 59,
          averageHeartRate: 70.51, sdnn: 30.25, rmssd: 29.75, source: "Test Apple Watch"),
        HealthHeartbeatSeriesItem(
          id: "h2", start: "2026-10-16T07:00:00+00:00", end: "2026-10-16T07:00:05+00:00",
          beatCount: 2, duration: 5.2, gapCount: 1, intervalCount: 0, averageHeartRate: nil,
          sdnn: nil, rmssd: nil, source: "Test Apple Watch"),
      ])
    #expect(
      result.text == """
        Heartbeat series, W: 2026-10-14 to 2026-10-20 (UTC)
        3 series

          2026-10-19 07:00   70.51 BPM average · SDNN 30.25 ms · RMSSD 29.75 ms · 60 beats · Test Apple Watch   h1
          2026-10-16 07:00   2 beats · 1 gap · Test Apple Watch   h2

        Showing the 2 most recent series.

        """)
  }

  @Test func listsAPageOfBeatsALineEach() {
    let result = HealthHeartbeatSeriesBeatsResult(
      timeZone: "UTC", id: "h1", start: "2026-10-19T07:00:00+00:00", beatCount: 40,
      beats: [
        HealthHeartbeat(time: 7.5, interval: 812.3, precededByGap: false),
        HealthHeartbeat(time: 12.1, interval: nil, precededByGap: true),
      ],
      nextCursor: "12")
    #expect(
      result.text == """
        Heartbeat series h1   2026-10-19 07:00 (UTC)
        40 beats. Seconds from the start, and ms since the beat before:
          7.5 s   812.3 ms
          12.1 s   –   after a gap

        More: --cursor 12

        """)
  }
}
