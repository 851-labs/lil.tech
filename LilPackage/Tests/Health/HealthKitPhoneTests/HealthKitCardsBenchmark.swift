import Foundation
import HealthCards
import HealthKit
import HealthKitAccess
import Testing

/// How long the iPhone's card engine takes over a year of heart rate every 5 minutes (105,120
/// samples, about what a Watch records), the design's yardstick (docs/decisions/cards.md, The
/// iPhone). Only when asked, since writing the year takes a while:
/// `TEST_RUNNER_LIL_HEALTHKIT_BENCHMARK=1 scripts/test-iphone-healthkit HealthKitCardsBenchmark`.
@Suite(
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["LIL_HEALTHKIT_BENCHMARK"] == "1"))
struct HealthKitCardsBenchmark {
  @Test
  func aYearOfHeartRate() async throws {
    let health = try await SyntheticHealthKit.empty()
    var samples: [HKQuantitySample] = []
    var time = date(1, 1)
    var index = 0
    while time < date(1, 1).addingTimeInterval(365 * 86_400) {
      samples.append(SyntheticHealthKit.sample(heartRate, 50 + Double((index * 37) % 70), at: time))
      time.addTimeInterval(5 * 60)
      index += 1
    }
    let clock = ContinuousClock()
    let saving = clock.now
    try await health.save(samples)
    print("Benchmark: saved \(samples.count) samples in \(clock.now - saving)")

    let engine = HealthKitCardEngine(store: health.store)
    let cards: [(String, String, CardRange)] = [
      (
        "Y by the month, average",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}], "range": "Y"}"#,
        .year
      ),
      (
        "Y by the day, highest, with a 7-day average",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "max"}], "formulas": [{"id": "t", "kind": "movingAverage", "of": "a", "points": 7}], "bucket": "day", "range": "Y"}"#,
        .year
      ),
      (
        "Y by the day, first before noon",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}}], "bucket": "day", "range": "Y"}"#,
        .year
      ),
      (
        "Y by the day, of a device",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "filter": {"deviceModels": ["Watch"]}}], "bucket": "day", "range": "Y"}"#,
        .year
      ),
      (
        "W by the day, average",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}], "range": "W"}"#,
        .week
      ),
    ]
    for (name, json, range) in cards {
      let card = try CardSpec(inputJSON: Data(json.utf8))
      let run = CardRun(spec: card, range: range, date: date(10, 20), now: now, calendar: london)
      var durations: [Duration] = []
      for _ in 0..<3 {
        let start = clock.now
        _ = try await engine.data(run)
        durations.append(clock.now - start)
      }
      print("Benchmark: \(name): \(durations.map(\.description).joined(separator: ", "))")
    }

    // Of which reading the samples from HealthKit, as readings:
    let year = ms(date(1, 1))..<ms(date(1, 1).addingTimeInterval(366 * 86_400))
    let reading = clock.now
    let readings = try await engine.readings(
      of: heartRate, in: year, filter: nil, needsSampleIDs: false)
    print("Benchmark: reading \(readings.count) readings: \(clock.now - reading)")

    // Cancelled 50 ms in, a year's run stops rather than reading the year.
    let card = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}], "range": "Y"}"#
          .utf8))
    let run = CardRun(spec: card, range: .year, date: date(10, 20), now: now, calendar: london)
    let start = clock.now
    let task = Task { try await engine.data(run) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    _ = await task.result
    print("Benchmark: cancelled after 50 ms, stopped after \(clock.now - start)")
  }
}
