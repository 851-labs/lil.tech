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

    // Totals: steps every 10 minutes from 7:00 to 23:00 (35,040 samples), which HealthKit sums
    // by the hour.
    var stepSamples: [HKQuantitySample] = []
    var day = date(1, 1)
    for _ in 0..<365 {
      for minute in stride(from: 7 * 60, to: 23 * 60, by: 10) {
        stepSamples.append(
          SyntheticHealthKit.sample(
            steps, Double(minute % 400),
            at: day.addingTimeInterval(Double(minute) * 60), minutes: 10))
      }
      day = london.date(byAdding: .day, value: 1, to: day)!
    }
    try await health.save(stepSamples)
    for (name, json, range) in [
      (
        "steps, Y (average days by the month)",
        #"{"version": 1, "display": {"name": "S"}, "series": [{"type": "Steps"}], "range": "Y"}"#,
        CardRange.year
      ),
      (
        "steps by the day, Y",
        #"{"version": 1, "display": {"name": "S"}, "series": [{"type": "Steps"}], "bucket": "day", "range": "Y"}"#,
        .year
      ),
      (
        "steps, W",
        #"{"version": 1, "display": {"name": "S"}, "series": [{"type": "Steps"}], "range": "W"}"#,
        .week
      ),
    ] {
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

    // Windows (851-3200): a Watch's night ending on every day of the year (in bed, Core, awake
    // twice, Deep, REM), falling asleep between 22:00 and 01:00, and a run at 07:00 every other
    // day.
    var nights: [HKSample] = []
    day = date(1, 1)
    for index in 0..<365 {
      let bed = day.addingTimeInterval((-2 + Double((index * 5) % 7) / 2) * 3600)
      func at(_ hours: Double) -> Date { bed.addingTimeInterval(hours * 3600) }
      nights += [
        SyntheticHealthKit.sleep(.inBed, at(-0.4), at(8.2)),
        SyntheticHealthKit.sleep(.asleepCore, at(0), at(2)),
        SyntheticHealthKit.sleep(.awake, at(2), at(2 + 1 / 6)),
        SyntheticHealthKit.sleep(.asleepDeep, at(2 + 1 / 6), at(4)),
        SyntheticHealthKit.sleep(.asleepREM, at(4), at(7.5)),
        SyntheticHealthKit.sleep(.awake, at(7.5), at(7.75)),
      ]
      day = london.date(byAdding: .day, value: 1, to: day)!
    }
    try await health.save(nights)
    day = date(1, 1)
    for index in 0..<365 {
      if index % 2 == 0 {
        _ = try await health.workout(.running, at: day.addingTimeInterval(7 * 3600), minutes: 45)
      }
      day = london.date(byAdding: .day, value: 1, to: day)!
    }
    let windowCards: [(String, String)] = [
      (
        "heart rate asleep, by the night, with a 7-night average, Y",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "asleep"}}], "formulas": [{"id": "t", "kind": "movingAverage", "of": "a", "points": 7}], "bucket": "night", "range": "Y"}"#
      ),
      (
        "heart rate in the 5 minutes before sleep, by the night, Y",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "Y"}"#
      ),
      (
        "heart rate while running, by the day, Y",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "workout", "activities": [37]}}], "bucket": "day", "range": "Y"}"#
      ),
      (
        "heart rate asleep, by the night, W",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "W"}"#
      ),
    ]
    for (name, json) in windowCards {
      let card = try CardSpec(inputJSON: Data(json.utf8))
      let run = CardRun(
        spec: card, range: card.range, date: date(10, 20), now: now, calendar: london)
      var durations: [Duration] = []
      for _ in 0..<3 {
        let start = clock.now
        _ = try await engine.data(run)
        durations.append(clock.now - start)
      }
      print("Benchmark: \(name): \(durations.map(\.description).joined(separator: ", "))")

      // How else its stretches could be read: a query each, one after another or several at
      // once; stretches less than an hour apart as one, one after another or 8 at once; or the
      // whole span in one query.
      var windowed = run
      var results: [CardWindowFetchResult] = []
      for fetch in run.windowFetches { results.append(try await engine.window(fetch)) }
      windowed = windowed.windowed(results)
      guard case .stretchReadings(let stretches, _, _) = windowed.fetches[0].kind else { continue }
      let each = stretches.map { $0.start..<$0.end }
      var grouped: [Range<Int>] = []
      for range in each {
        if let last = grouped.last, range.lowerBound - last.upperBound < 3_600_000 {
          grouped[grouped.count - 1] = last.lowerBound..<range.upperBound
        } else {
          grouped.append(range)
        }
      }
      let span = [each.first!.lowerBound..<each.last!.upperBound]
      for (strategy, ranges, width) in [
        ("a query a stretch, one at a time", each, 1),
        ("a query a stretch, 4 at once", each, 4),
        ("stretches an hour apart as one, one at a time", grouped, 1),
        ("stretches an hour apart as one, 8 at once", grouped, 8),
        ("the whole span", span, 1),
      ] {
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
          for (index, range) in ranges.enumerated() {
            if index >= width { try await group.next() }
            group.addTask {
              _ = try await engine.readings(
                of: heartRate, in: range, filter: nil, needsSampleIDs: false)
            }
          }
          try await group.waitForAll()
        }
        print(
          "Benchmark:   \(strategy) (\(ranges.count) queries): \(clock.now - start)")
      }
    }

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
