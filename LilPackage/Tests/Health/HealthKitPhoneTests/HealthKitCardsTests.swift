import Foundation
import HealthCards
import HealthKit
import HealthKitAccess
import Testing

/// The iPhone's card engine against the simulator's HealthKit (851-3199): synthetic samples are
/// written, then each card's data from HealthKit is compared with what the shared core computes
/// from the same samples read as the Mac reads them (`reference(_:samples:)`), within the
/// conformance cases' 1e-9.
@Suite(.serialized)
struct HealthKitCardsTests {
  // MARK: - Readings

  /// New samples each time: HealthKit ignores a sample saved again after it was deleted, as
  /// each test deletes the one before's.
  ///
  /// Heart rate every 7 minutes in October (over London's change back to GMT) and September, with
  /// resting heart rate each morning, weight morning and evening, and sound levels.
  static var readingSamples: [HKQuantitySample] {
    var samples: [HKQuantitySample] = []
    var time = date(9, 1)
    var index = 0
    while time < date(11, 1) {
      let value = 55 + Double((index * 37) % 50)
      samples.append(SyntheticHealthKit.sample(heartRate, value, at: time))
      time.addTimeInterval(7 * 60)
      index += 1
    }
    for day in 0..<61 {
      let morning = london.date(byAdding: .day, value: day, to: date(9, 1))!
      samples.append(
        SyntheticHealthKit.sample(
          restingHeartRate, 50 + Double(day % 7), at: morning.addingTimeInterval(6 * 3600)))
      // Some days without a morning weigh-in.
      if day % 5 != 3 {
        samples.append(
          SyntheticHealthKit.sample(
            bodyMass, 70 + Double(day) / 10, at: morning.addingTimeInterval(7.5 * 3600)))
      }
      samples.append(
        SyntheticHealthKit.sample(
          bodyMass, 71 + Double(day) / 10, at: morning.addingTimeInterval(20 * 3600)))
      for hour in [9, 13, 18] {
        samples.append(
          SyntheticHealthKit.sample(
            soundLevel, 60 + Double((day * hour) % 25),
            at: morning.addingTimeInterval(Double(hour) * 3600), minutes: 20))
      }
    }
    return samples
  }

  static let readingCards: [(String, String)] = [
    (
      "heart rate",
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}], "range": "W"}"#
    ),
    (
      "lowest heart rate",
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "min"}], "bucket": "day", "range": "M"}"#
    ),
    (
      "highest heart rate by the week",
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "max"}], "bucket": "week", "range": "M"}"#
    ),
    (
      "readings of heart rate",
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "count"}], "bucket": "hour", "range": "D"}"#
    ),
    (
      "heart rate overnight",
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "timeOfDay", "from": "22:00", "to": "06:00"}}], "bucket": "day", "range": "M"}"#
    ),
    (
      "morning weight",
      #"{"version": 1, "display": {"name": "Morning Weight"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#
    ),
    (
      "latest weight",
      #"{"version": 1, "display": {"name": "W"}, "series": [{"type": "Weight", "aggregation": "latest"}], "bucket": "day", "range": "W"}"#
    ),
    (
      "heart rate above resting",
      #"{"version": 1, "display": {"name": "Gap"}, "series": [{"type": "HeartRate", "hidden": true}, {"type": "RestingHeartRate", "hidden": true}], "formulas": [{"id": "gap", "kind": "difference", "of": ["a", "b"]}], "bucket": "day", "range": "M"}"#
    ),
    (
      "sound levels",
      #"{"version": 1, "display": {"name": "Sound"}, "series": [{"type": "HKQuantityTypeIdentifierEnvironmentalAudioExposure"}], "bucket": "day", "range": "W"}"#
    ),
  ]

  @Test
  func readingsComputeAsTheCoreComputesThem() async throws {
    let health = try await SyntheticHealthKit.empty()
    let samples = Self.readingSamples
    try await health.save(samples)
    let engine = HealthKitCardEngine(store: health.store)
    let mac = Reference(samples: samples)
    for (name, json) in Self.readingCards {
      let card = try CardSpec(inputJSON: Data(json.utf8))
      for range in CardRange.allCases where card.bucket.ranges.contains(range) {
        for day in [date(10, 20), date(10, 25), date(9, 3)] {
          let run = CardRun(spec: card, range: range, date: day, now: now, calendar: london)
          let data = try await engine.data(run)
          let expected = mac(run)
          #expect(
            data.rounded == expected.rounded, "\(name), \(range) containing \(day)")
          #expect(expected.series.contains { !$0.points.isEmpty }, "\(name), \(range)")
        }
      }
    }
  }

  @Test
  func valuesAreInCatalogUnits() async throws {
    let health = try await SyntheticHealthKit.empty()
    // 98.6 °F is 37 °C, the catalog's unit.
    try await health.save([
      HKQuantitySample(
        type: HKQuantityType(.bodyTemperature),
        quantity: HKQuantity(unit: .degreeFahrenheit(), doubleValue: 98.6), start: date(10, 20, 8),
        end: date(10, 20, 8))
    ])
    let card = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "T"}, "series": [{"type": "BodyTemperature"}], "range": "W"}"#
          .utf8))
    let data = try await HealthKitCardEngine(store: health.store).data(
      CardRun(spec: card, range: .week, date: date(10, 20), now: now, calendar: london))
    let point = try #require(data.series[0].points.first)
    #expect(abs(point.value - 37) < 1e-9)
    #expect(point.start == date(10, 20))
  }

  @Test
  func firstAndLatestBreakTiesBySampleID() async throws {
    let health = try await SyntheticHealthKit.empty()
    let samples = [70.0, 71, 72].map {
      SyntheticHealthKit.sample(bodyMass, $0, at: date(10, 20, 8), minutes: 1)
    }
    try await health.save(samples)
    let ids = samples.map { $0.uuid.uuidString.lowercased() }
    for (aggregation, pick) in [("first", ids.min()!), ("latest", ids.max()!)] {
      let card = try CardSpec(
        inputJSON: Data(
          #"{"version": 1, "display": {"name": "W"}, "series": [{"type": "Weight", "aggregation": "\#(aggregation)"}], "bucket": "day", "range": "W"}"#
            .utf8))
      let data = try await HealthKitCardEngine(store: health.store).data(
        CardRun(spec: card, range: .week, date: date(10, 20), now: now, calendar: london))
      let expected = samples[ids.firstIndex(of: pick)!].quantity.doubleValue(
        for: .gramUnit(with: .kilo))
      #expect(data.series[0].points.map(\.value) == [expected], "\(aggregation)")
    }
  }

  // MARK: - Totals

  /// Steps every 10 minutes from 7:00 to 23:00, each within its hour, over the year to Nov 1,
  /// and a walk across one midnight.
  static var stepSamples: [HKQuantitySample] {
    var samples: [HKQuantitySample] = []
    var day = date(1, 1)
    var index = 0
    while day < date(11, 1) {
      for minute in stride(from: 7 * 60, to: 23 * 60, by: 10) where (index + minute) % 3 != 0 {
        samples.append(
          SyntheticHealthKit.sample(
            steps, Double((index * 13 + minute) % 400),
            at: day.addingTimeInterval(Double(minute) * 60), minutes: 10))
      }
      day = london.date(byAdding: .day, value: 1, to: day)!
      index += 1
    }
    return samples
  }

  static let totalCards: [(String, String)] = [
    (
      "steps",
      #"{"version": 1, "display": {"name": "Steps"}, "series": [{"type": "Steps"}], "range": "W"}"#
    ),
    (
      "steps by the week",
      #"{"version": 1, "display": {"name": "Steps"}, "series": [{"type": "Steps"}], "bucket": "week", "range": "M"}"#
    ),
    (
      "steps by the day, with a moving average",
      #"{"version": 1, "display": {"name": "Steps"}, "series": [{"type": "Steps"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "bucket": "day", "range": "M"}"#
    ),
  ]

  @Test
  func totalsComputeAsTheCoreComputesThem() async throws {
    let health = try await SyntheticHealthKit.empty()
    let samples = Self.stepSamples
    try await health.save(samples)
    let engine = HealthKitCardEngine(store: health.store)
    let mac = Reference(samples: samples)
    for (name, json) in Self.totalCards {
      let card = try CardSpec(inputJSON: Data(json.utf8))
      for range in CardRange.allCases where card.bucket.ranges.contains(range) {
        for day in [date(10, 20), date(10, 25), date(3, 29)] {
          let run = CardRun(spec: card, range: range, date: day, now: now, calendar: london)
          let data = try await engine.data(run)
          let expected = mac(run)
          #expect(data.rounded == expected.rounded, "\(name), \(range) containing \(day)")
          #expect(!expected.series[0].points.isEmpty, "\(name), \(range)")
        }
      }
    }
  }

  /// HealthKit shares a sample between the hours it spans, as the Mac's 30-minute statistics
  /// share it, so a walk across midnight counts toward both days.
  @Test
  func aSampleAcrossMidnightIsShared() async throws {
    let health = try await SyntheticHealthKit.empty()
    try await health.save([
      SyntheticHealthKit.sample(steps, 600, at: date(10, 20, 23, 30), minutes: 60)
    ])
    let card = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "Steps"}, "series": [{"type": "Steps"}], "range": "W"}"#
          .utf8))
    let data = try await HealthKitCardEngine(store: health.store).data(
      CardRun(spec: card, range: .week, date: date(10, 20), now: now, calendar: london))
    #expect(data.series[0].points.map(\.start) == [date(10, 20), date(10, 21)])
    #expect(data.series[0].points.map(\.value).map { $0.rounded() } == [300, 300])
  }

  // MARK: - Filters

  @Test
  func filtersBySourceAndDeviceModel() async throws {
    let health = try await SyntheticHealthKit.empty()
    let watch = HKDevice(
      name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch", hardwareVersion: nil,
      firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    let phone = HKDevice(
      name: "iPhone", manufacturer: "Apple Inc.", model: "iPhone", hardwareVersion: nil,
      firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    let samples = (0..<200).map { index in
      SyntheticHealthKit.sample(
        heartRate, 50 + Double(index % 60),
        at: date(10, 19).addingTimeInterval(Double(index) * 37 * 60),
        device: index % 3 == 0 ? phone : watch)
    }
    try await health.save(samples)
    let engine = HealthKitCardEngine(store: health.store)
    let bundleID = Bundle.main.bundleIdentifier!
    func card(_ filter: String) throws -> CardSpec {
      try CardSpec(
        inputJSON: Data(
          #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "max", "filter": \#(filter)}], "bucket": "day", "range": "W"}"#
            .utf8))
    }
    func data(_ spec: CardSpec) async throws -> CardData {
      try await engine.data(
        CardRun(spec: spec, range: .week, date: date(10, 20), now: now, calendar: london))
    }
    func expected(_ spec: CardSpec, _ samples: [HKQuantitySample]) -> CardData {
      reference(
        CardRun(spec: spec, range: .week, date: date(10, 20), now: now, calendar: london),
        samples: samples)
    }

    let ours = try card(#"{"sources": ["\#(bundleID)"]}"#)
    #expect(try await data(ours).rounded == expected(ours, samples).rounded)
    let others = try await data(try card(#"{"sources": ["com.example.other"]}"#))
    #expect(others.series[0].points.isEmpty)
    #expect(others.summary == nil)

    let watches = try card(#"{"deviceModels": ["Watch"]}"#)
    let watchSamples = samples.filter { $0.device?.model == "Watch" }
    #expect(try await data(watches).rounded == expected(watches, watchSamples).rounded)
    let both = try card(#"{"sources": ["\#(bundleID)"], "deviceModels": ["iPhone"]}"#)
    let phoneSamples = samples.filter { $0.device?.model == "iPhone" }
    #expect(try await data(both).rounded == expected(both, phoneSamples).rounded)
    let neither = try await data(try card(#"{"deviceModels": ["iPad"]}"#))
    #expect(neither.series[0].points.isEmpty)
  }

  // MARK: - Headlines

  @Test
  func headlinesAreFoundAsTheMacFindsThem() async throws {
    let health = try await SyntheticHealthKit.empty()
    let samples = [
      SyntheticHealthKit.sample(heartRate, 61, at: date(10, 28, 9)),
      SyntheticHealthKit.sample(heartRate, 64, at: date(10, 30, 21, 15)),
      // Started after now: not the latest.
      SyntheticHealthKit.sample(heartRate, 99, at: now.addingTimeInterval(60)),
      SyntheticHealthKit.sample(steps, 400, at: date(10, 29, 12), minutes: 10),
      SyntheticHealthKit.sample(steps, 300, at: date(10, 29, 18), minutes: 10),
    ]
    try await health.save(samples)
    let engine = HealthKitCardEngine(store: health.store)

    // The latest reading, and the week ending on its day.
    let heart = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}], "range": "W"}"#
          .utf8))
    let reading = try #require(try await engine.headline(heart, now: now, calendar: london))
    #expect(reading.value == 64)
    #expect(reading.date == date(10, 30, 21, 15))
    #expect(reading.kind == .reading)
    let readingRun = CardRun(headlineOf: heart, endingOn: reading.date, calendar: london)
    #expect(reading.data.rounded == reference(readingRun, samples: samples).rounded)

    // The latest day with steps.
    let total = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "Steps"}, "series": [{"type": "Steps"}], "range": "W"}"#
          .utf8))
    let day = try #require(try await engine.headline(total, now: now, calendar: london))
    #expect(day.value == 700)
    #expect(day.date == date(10, 29))
    #expect(day.kind == .bucket)

    // A window searches back from now.
    let evening = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "timeOfDay", "from": "18:00", "to": "23:00"}}], "bucket": "day", "range": "W"}"#
          .utf8))
    let found = try #require(try await engine.headline(evening, now: now, calendar: london))
    #expect(found.value == 64)
    #expect(found.date == date(10, 30))

    // Nothing at all is No Data.
    let weight = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "W"}, "series": [{"type": "Weight"}], "range": "W"}"#
          .utf8))
    #expect(try await engine.headline(weight, now: now, calendar: london) == nil)
  }

  // MARK: - Cancelling

  @Test
  func cancellingStopsARun() async throws {
    let health = try await SyntheticHealthKit.empty()
    try await health.save(Self.readingSamples)
    let card = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate"}], "range": "Y"}"#
          .utf8))
    let engine = HealthKitCardEngine(store: health.store)
    let run = CardRun(spec: card, range: .year, date: date(10, 20), now: now, calendar: london)
    // Before it starts.
    let early = Task { try await engine.data(run) }
    early.cancel()
    await #expect(throws: CancellationError.self) { try await early.value }
    // While HealthKit reads the year's samples: the query stops and the run throws, rather than
    // returning the card. A tenth of the way through an uncancelled run.
    let clock = ContinuousClock()
    let start = clock.now
    let whole = try await engine.data(run)
    let took = clock.now - start
    #expect(whole.series[0].points.count == 2, "September's and October's")
    let late = Task { try await engine.data(run) }
    try await Task.sleep(for: took / 10)
    late.cancel()
    await #expect(throws: CancellationError.self) { try await late.value }
  }
}

// MARK: - Support

let heartRate = "HKQuantityTypeIdentifierHeartRate"
let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
let bodyMass = "HKQuantityTypeIdentifierBodyMass"
let steps = "HKQuantityTypeIdentifierStepCount"
let soundLevel = "HKQuantityTypeIdentifierEnvironmentalAudioExposure"

/// London, weeks from Monday: a time zone with daylight saving, which needn't be the simulator's.
let london: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/London")!
  calendar.firstWeekday = 2
  return calendar
}()

/// When the tests run, as far as cards know: after every sample.
let now = date(11, 1, 9)

func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
  london.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

/// What the core computes from `samples` read as the Mac reads them (`Reference`).
func reference(_ run: CardRun, samples: [HKSample]) -> CardData {
  Reference(samples: samples)(run)
}

/// What the core computes from samples read as the Mac reads them: readings by start, filtered by
/// source and device, and totals added up by the start of each sample (which the tests keep within
/// an hour, so HealthKit's sharing doesn't matter). Sleep analysis records and workouts that
/// overlap a window fetch's range, by start, and each stretch's readings, one stretch after
/// another, as the Mac's `cardData` reads them (851-3200). Made once for a test's samples, then
/// run for each card.
struct Reference {
  let bundleID = Bundle.main.bundleIdentifier!
  let byType: [String: [CardReading]]
  let devices: [String: String?]
  let sleep: [CardSleepRecord]
  let workouts: [CardWorkout]

  init(samples: [HKSample]) {
    let quantities = samples.compactMap { $0 as? HKQuantitySample }
    byType = SyntheticHealthKit.readings(quantities)
    devices = Dictionary(
      uniqueKeysWithValues: quantities.map { ($0.uuid.uuidString.lowercased(), $0.device?.model) })
    let bundleID = bundleID
    sleep = samples.compactMap { $0 as? HKCategorySample }
      .sorted { $0.startDate < $1.startDate }
      .map {
        CardSleepRecord(
          start: ms($0.startDate), end: ms($0.endDate), value: $0.value, source: bundleID)
      }
    workouts = samples.compactMap { $0 as? HKWorkout }
      .sorted { $0.startDate < $1.startDate }
      .map {
        CardWorkout(
          start: ms($0.startDate), end: ms($0.endDate),
          activityType: Int($0.workoutActivityType.rawValue))
      }
  }

  func callAsFunction(_ run: CardRun) -> CardData {
    var run = run
    if !run.windowFetches.isEmpty {
      run = run.windowed(
        run.windowFetches.map { fetch in
          switch fetch {
          case .sleep(let range):
            .sleep(sleep.filter { $0.start < range.upperBound && $0.end > range.lowerBound })
          case .workouts(let range):
            .workouts(
              workouts.filter { $0.start < range.upperBound && $0.end > range.lowerBound })
          }
        })
    }
    return run.compute(
      run.fetches.map { fetch in
        switch fetch.kind {
        case .readings(let range, let filter, let needsSampleIDs):
          return .readings(
            readings(of: fetch.type, filter: filter, needsSampleIDs: needsSampleIDs) {
              range.contains($0.start)
            })
        case .stretchReadings(let stretches, let filter, let needsSampleIDs):
          // The stretches are in order and apart, so a reading's stretch is found in one pass,
          // and the readings come out stretch by stretch, as a query each gives them.
          var stretch = 0
          return .readings(
            readings(of: fetch.type, filter: filter, needsSampleIDs: needsSampleIDs) { reading in
              while stretch < stretches.count, stretches[stretch].end <= reading.start {
                stretch += 1
              }
              return stretch < stretches.count && stretches[stretch].start <= reading.start
            })
        case .totals(let range, let grain):
          var sums: [Date: Double] = [:]
          for reading in byType[fetch.type] ?? [] {
            let start = Date(timeIntervalSince1970: Double(reading.start) / 1000)
            guard range.contains(start) else { continue }
            sums[london.dateInterval(of: grain.component, for: start)!.start, default: 0] +=
              reading.value
          }
          return .totals(
            sums.sorted { $0.key < $1.key }.map { CardTotal(start: $0.key, sum: $0.value) })
        }
      })
  }

  /// The type's readings, oldest first, that `isIn` keeps and match `filter`.
  private func readings(
    of type: String, filter: CardSpec.Filter?, needsSampleIDs: Bool,
    _ isIn: (CardReading) -> Bool
  ) -> [CardReading] {
    (byType[type] ?? []).filter { reading in
      isIn(reading)
        && filter?.sources.map { $0.contains(bundleID) } ?? true
        && filter?.deviceModels.map { models in
          devices[reading.sampleID].flatMap { $0 }.map(models.contains) ?? false
        } ?? true
    }
    .map { reading in
      var reading = reading
      if !needsSampleIDs { reading.sampleID = "" }
      return reading
    }
  }
}

extension CardData {
  /// With every number to 10 significant digits, so data added up in another order compares
  /// equal, as the conformance cases' relative 1e-9 does.
  var rounded: CardData {
    func round(_ value: Double) -> Double {
      guard value != 0, value.isFinite else { return value }
      return Double(String(format: "%.10g", value))!
    }
    var data = self
    for index in data.series.indices {
      data.series[index].points = data.series[index].points.map {
        CardPoint(
          start: $0.start, value: round($0.value), minimum: round($0.minimum),
          maximum: round($0.maximum), readings: $0.readings)
      }
    }
    for index in data.formulas.indices {
      data.formulas[index].points = data.formulas[index].points.map {
        CardFormulaPoint(start: $0.start, value: round($0.value))
      }
    }
    data.summary = data.summary.map {
      CardSummary(
        kind: $0.kind, value: $0.value.map(round), minimum: $0.minimum.map(round),
        maximum: $0.maximum.map(round))
    }
    return data
  }
}
