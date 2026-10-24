import Foundation
import Testing

@testable import HealthCards

// What the engine's tests share (CardEngineTests, CardWindowsTests): synthetic readings, sleep and
// workouts, in London, and an in-memory engine.
let heartRate = "HKQuantityTypeIdentifierHeartRate"
let bodyMass = "HKQuantityTypeIdentifierBodyMass"
let steps = "HKQuantityTypeIdentifierStepCount"
let bodyTemperature = "HKQuantityTypeIdentifierBodyTemperature"
let hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"

/// London, weeks from Monday: a time zone with daylight saving.
let london: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/London")!
  calendar.firstWeekday = 2
  return calendar
}()

func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, year: Int = 2026)
  -> Date
{
  london.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

func ms(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

func reading(
  _ date: Date, _ value: Double, minutes: Double = 1, source: String = "com.example",
  id: String = ""
) -> CardReading {
  CardReading(
    start: ms(date), end: ms(date) + Int(minutes * 60_000), value: value, source: source,
    sampleID: id)
}

func spec(_ json: String) throws -> CardSpec {
  try CardSpec(inputJSON: Data(json.utf8))
}

/// Runs a spec as an engine would, over in-memory data: readings by type, cumulative types'
/// hourly totals, added up into the fetch's buckets as `cumulativeTotals` does, and sleep records
/// and workouts for windows.
func run(
  _ spec: CardSpec, _ range: CardRange, on day: Date, readings: [String: [CardReading]] = [:],
  hourlyTotals: [String: [CardTotal]] = [:], sleep: [CardSleepRecord] = [],
  workouts: [CardWorkout] = []
) -> CardData {
  let run = windowed(
    CardRun(spec: spec, range: range, date: day, now: day, calendar: london), sleep: sleep,
    workouts: workouts)
  return run.compute(fetch(run, readings: readings, hourlyTotals: hourlyTotals))
}

/// The run with its windows, from the records and workouts each window fetch's range overlaps.
func windowed(
  _ run: CardRun, sleep: [CardSleepRecord], workouts: [CardWorkout]
) -> CardRun {
  guard !run.windowFetches.isEmpty else { return run }
  return run.windowed(
    run.windowFetches.map { fetch in
      switch fetch {
      case .sleep(let range):
        .sleep(
          sleep.filter { $0.start < range.upperBound && $0.end > range.lowerBound }
            .sorted { $0.start < $1.start })
      case .workouts(let range):
        .workouts(workouts.filter { $0.start < range.upperBound && $0.end > range.lowerBound })
      }
    })
}

func fetch(
  _ run: CardRun, readings: [String: [CardReading]], hourlyTotals: [String: [CardTotal]]
) -> [CardFetchResult] {
  run.fetches.map { fetch in
    switch fetch.kind {
    case .readings(let range, _, _):
      return .readings((readings[fetch.type] ?? []).filter { range.contains($0.start) })
    case .stretchReadings(let stretches, _, _):
      return .readings(
        (readings[fetch.type] ?? []).filter { reading in
          stretches.contains { $0.start <= reading.start && reading.start < $0.end }
        })
    case .totals(let range, let grain):
      var sums: [Date: Double] = [:]
      for total in hourlyTotals[fetch.type] ?? [] where range.contains(total.start) {
        let start = london.dateInterval(of: grain.component, for: total.start)!.start
        sums[start, default: 0] += total.sum
      }
      return .totals(sums.map { CardTotal(start: $0.key, sum: $0.value) })
    }
  }
}
