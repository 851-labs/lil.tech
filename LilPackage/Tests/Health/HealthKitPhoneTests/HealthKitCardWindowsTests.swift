import Foundation
import HealthCards
import HealthKit
import HealthKitAccess
import Testing

// Sleep and workout windows from the simulator's HealthKit (851-3200): synthetic nights, workouts
// and heart rate, each card's data compared with what the core computes from the same samples
// read as the Mac reads them (`reference(_:samples:)`), and the Mac's own tests' answers on the
// same samples. In `HealthKitCardsTests`, whose tests run one at a time, since each empties
// HealthKit first.
extension HealthKitCardsTests {
  // MARK: - Every window, as the core computes it

  /// Nights ending on each day from Sep 1 to Nov 1 and Mar 22 to Apr 5 (over both of London's
  /// changes of clock), falling asleep between 22:00 and 01:00: in bed, lying awake, Core, awake
  /// in the night, Deep, REM and awake again, or a night of Asleep without stages every sixth
  /// day; an afternoon nap every fourth day, a day's sleep instead of a night on days whose
  /// date is 4 more than a multiple of 9. Heart rate every 2 minutes from 20:00 to 10:00 and every
  /// 10 the rest of the day, one in four from an iPhone and the rest from a Watch, and resting
  /// heart rate each morning.
  static var windowSamples: [HKSample] {
    let watch = device("Watch")
    let phone = device("iPhone")
    var samples: [HKSample] = []
    var index = 0
    for (start, end) in [(date(8, 31), date(11, 2)), (date(3, 21), date(4, 6))] {
      var day = start
      while day < end {
        let dayOfMonth = london.component(.day, from: day)
        let ordinal = london.ordinality(of: .day, in: .era, for: day)!
        func at(_ hours: Double) -> Date { day.addingTimeInterval(hours * 3600) }
        if dayOfMonth % 9 == 4 {
          samples.append(SyntheticHealthKit.sleep(.asleepCore, at(13), at(14.5)))
        } else {
          let bed = -2 + Double((ordinal * 5) % 7) / 2
          func from(_ hours: Double, _ to: Double) -> (Date, Date) {
            (at(bed + hours), at(bed + to))
          }
          var night: [(HKCategoryValueSleepAnalysis, (Date, Date))] = [
            (.inBed, from(-0.4, 8.2)), (.awake, from(-0.25, 0)),
          ]
          if ordinal % 6 == 0 {
            night.append((.asleepUnspecified, from(0, 7)))
          } else {
            night += [
              (.asleepCore, from(0, 2)), (.awake, from(2, 2 + 1 / 6)),
              (.asleepDeep, from(2 + 1 / 6, 4)), (.asleepREM, from(4, 7.5)),
              (.awake, from(7.5, 7.75)),
            ]
          }
          if ordinal % 4 == 0 { night.append((.asleepCore, (at(15), at(16)))) }
          samples += night.map { SyntheticHealthKit.sleep($0, $1.0, $1.1) }
        }
        samples.append(
          SyntheticHealthKit.sample(restingHeartRate, 48 + Double(ordinal % 9), at: at(6)))
        day = london.date(byAdding: .day, value: 1, to: day)!
      }
      // One series over the whole span, by the local clock's hour, so no two readings start
      // together on days of 23 or 25 hours: a time-weighted average of readings starting in the
      // same millisecond depends on their order, which HealthKit and SQLite needn't share.
      var time = start
      while time < end {
        let hour = london.component(.hour, from: time)
        samples.append(
          SyntheticHealthKit.sample(
            heartRate, 45 + Double((index * 37) % 40), at: time,
            device: index % 4 == 0 ? phone : watch))
        index += 1
        time.addTimeInterval(hour < 10 || hour >= 20 ? 120 : 600)
      }
    }
    return samples
  }

  /// Runs at 07:00 on even days, cycling at 18:00 on days not 1 more than a multiple of 3, a run
  /// across midnight into Oct 25 (the night clocks go back), and another workout overlapping a
  /// run on Oct 20.
  static func saveWindowWorkouts(_ health: SyntheticHealthKit) async throws -> [HKWorkout] {
    var workouts: [HKWorkout] = []
    for (start, end) in [(date(8, 31), date(11, 2)), (date(3, 21), date(4, 6))] {
      var day = start
      while day < end {
        let dayOfMonth = london.component(.day, from: day)
        if dayOfMonth % 2 == 0 {
          workouts.append(
            try await health.workout(.running, at: day.addingTimeInterval(7 * 3600), minutes: 30))
        }
        if dayOfMonth % 3 != 1 {
          workouts.append(
            try await health.workout(.cycling, at: day.addingTimeInterval(18 * 3600), minutes: 60))
        }
        day = london.date(byAdding: .day, value: 1, to: day)!
      }
    }
    workouts.append(try await health.workout(.running, at: date(10, 24, 23, 30), minutes: 60))
    workouts.append(try await health.workout(.other, at: date(10, 20, 7, 15), minutes: 30))
    return workouts
  }

  static func windowCards(bundleID: String) -> [(String, String)] {
    [
      (
        "sleeping heart rate",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "W"}"#
      ),
      (
        "lowest heart rate asleep by the week",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "min", "window": {"kind": "asleep"}}], "bucket": "week", "range": "M"}"#
      ),
      (
        "heart rate in the 5 minutes before falling asleep",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "W"}"#
      ),
      (
        "readings in the 30 minutes after waking",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "count", "window": {"kind": "afterWaking", "minutes": 30}}], "bucket": "night", "range": "W"}"#
      ),
      (
        "the first reading after waking, by the month",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "first", "window": {"kind": "afterWaking", "minutes": 60}}], "bucket": "month", "range": "Y"}"#
      ),
      (
        "sleeping heart rate with a 7-night average",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "asleep"}}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "bucket": "night", "range": "M"}"#
      ),
      (
        "sleeping heart rate above resting",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "hidden": true, "window": {"kind": "asleep"}}, {"type": "RestingHeartRate", "hidden": true}], "formulas": [{"id": "gap", "kind": "difference", "of": ["a", "b"]}], "bucket": "night", "range": "M"}"#
      ),
      (
        "sleeping heart rate from a Watch",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "max", "filter": {"deviceModels": ["Watch"]}, "window": {"kind": "asleep"}}], "bucket": "night", "range": "W"}"#
      ),
      (
        "sleeping heart rate from this app",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "filter": {"sources": ["\#(bundleID)"]}, "window": {"kind": "asleep"}}], "bucket": "night", "range": "W"}"#
      ),
      (
        "heart rate while running",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "workout", "activities": [37]}}], "bucket": "day", "range": "W"}"#
      ),
      (
        "highest heart rate in any workout, by the hour",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "max", "window": {"kind": "workout", "activities": null}}], "bucket": "hour", "range": "D"}"#
      ),
      (
        "heart rate while cycling",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "window": {"kind": "workout", "activities": ["Cycling"]}}], "range": "W"}"#
      ),
      (
        "the latest reading in a workout, by the week",
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "HeartRate", "aggregation": "latest", "window": {"kind": "workout", "activities": null}}], "bucket": "week", "range": "M"}"#
      ),
    ]
  }

  @Test
  func eventWindowsComputeAsTheCoreComputesThem() async throws {
    let health = try await SyntheticHealthKit.empty()
    var samples = Self.windowSamples
    try await health.save(samples)
    samples += try await Self.saveWindowWorkouts(health)
    let engine = HealthKitCardEngine(store: health.store)
    let mac = Reference(samples: samples)
    for (name, json) in Self.windowCards(bundleID: Bundle.main.bundleIdentifier!) {
      let card = try CardSpec(inputJSON: Data(json.utf8))
      for range in CardRange.allCases where card.bucket.ranges.contains(range) {
        // Over the change back to GMT (Oct 25), the change to BST (Mar 29), and the first night.
        for day in [date(10, 20), date(10, 26), date(3, 29), date(9, 3)] {
          let run = CardRun(spec: card, range: range, date: day, now: now, calendar: london)
          let data = try await engine.data(run)
          let expected = mac(run)
          #expect(
            data.rounded == expected.rounded,
            "\(name), \(range) containing \(day): \(differences(data.rounded, expected.rounded))")
          #expect(
            expected.series.contains { !$0.points.isEmpty }, "\(name), \(range) containing \(day)")
        }
      }
    }

    // The nights clocks change are there, and nights crossing midnight are their days'.
    let sleeping = try CardSpec(inputJSON: Data(Self.windowCards(bundleID: "")[0].1.utf8))
    for (day, night) in [(date(10, 20), date(10, 25)), (date(3, 29), date(3, 29))] {
      let data = try await engine.data(
        CardRun(spec: sleeping, range: .week, date: day, now: now, calendar: london))
      #expect(data.series[0].points.contains { $0.start == night }, "Night of \(night)")
    }
  }

  // MARK: - The Mac's answers

  /// A Watch's night ending on Oct `day`: Core from 23:00, awake 01:00 to 01:10, REM to 06:30,
  /// in bed from 22:30 to 07:00, and a nap at 15:00 the next afternoon. The Mac's test
  /// (`CardQueriesTests.sleepWindows`) also has an iPhone's estimate of the night, which the
  /// Watch's longer night outweighs; here every sample is this app's, so it's left out.
  private static func night(_ day: Int) -> [HKCategorySample] {
    let midnight = date(10, day)
    func at(_ hours: Double) -> Date { midnight.addingTimeInterval(hours * 3600) }
    return [
      SyntheticHealthKit.sleep(.inBed, at(-1.5), at(7)),
      SyntheticHealthKit.sleep(.asleepCore, at(-1), at(1)),
      SyntheticHealthKit.sleep(.awake, at(1), at(1 + 10 / 60)),
      SyntheticHealthKit.sleep(.asleepREM, at(1 + 10 / 60), at(6.5)),
      SyntheticHealthKit.sleep(.asleepCore, at(15), at(16)),
    ]
  }

  /// Examples 2 and 4, with the Mac's answers on the same samples: heart rate while asleep, in
  /// the 5 minutes before falling asleep and after waking, per night, and the headline's night.
  @Test
  func sleepWindowsReadAsTheMacReadsThem() async throws {
    let health = try await SyntheticHealthKit.empty()
    var samples: [HKSample] = Self.night(20) + Self.night(21)
    // A reading a minute from 22:00 to 08:00: 50 asleep, 70 awake in the night, 80 up, and 60 to
    // 64 in the 5 minutes before sleep.
    for day in [20, 21] {
      for minute in -120..<480 {
        let value: Double =
          switch minute {
          case -65..<(-60): 60 + Double(minute + 65)
          case -60..<60, 70..<390: 50 + Double(day - 20)
          case 60..<70: 70
          default: 80
          }
        samples.append(
          SyntheticHealthKit.sample(
            heartRate, value, at: date(10, day).addingTimeInterval(Double(minute) * 60)))
      }
    }
    try await health.save(samples)
    let engine = HealthKitCardEngine(store: health.store)
    func card(_ series: String) throws -> CardSpec {
      try CardSpec(
        inputJSON: Data(
          #"{"version": 1, "display": {"name": "Card"}, "series": [\#(series)], "bucket": "night", "range": "W"}"#
            .utf8))
    }
    func data(_ series: String) async throws -> CardData {
      try await engine.data(
        CardRun(
          spec: try card(series), range: .week, date: date(10, 20), now: date(10, 22),
          calendar: london))
    }
    let asleep = try await data(#"{"type": "Heart Rate", "window": {"kind": "asleep"}}"#)
    #expect(asleep.series[0].points.map(\.start) == [date(10, 20), date(10, 21)])
    #expect(asleep.series[0].points.map(\.value) == [50, 51])
    // 120 minutes of Core and 320 of REM a night.
    #expect(asleep.series[0].points.map(\.readings) == [440, 440])
    let before = try await data(
      #"{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}"#)
    #expect(before.series[0].points.map(\.value) == [62, 62])
    let after = try await data(
      #"{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "afterWaking", "minutes": 20}}"#
    )
    #expect(after.series[0].points.map(\.value) == [20, 20])

    // Its headline searches back from now for the latest night.
    let headline = try await engine.headline(
      try card(#"{"type": "Heart Rate", "window": {"kind": "asleep"}}"#), now: date(10, 23, 9),
      calendar: london)
    #expect(headline?.value == 51)
    #expect(headline?.date == date(10, 21))
  }

  /// Readings during workouts of the activities given, with the Mac's answers on the same samples
  /// (`CardQueriesTests.workoutWindows`): a run the evening before the period, across midnight,
  /// counts its minutes after midnight on the period's first day.
  @Test
  func workoutWindowsReadAsTheMacReadsThem() async throws {
    let health = try await SyntheticHealthKit.empty()
    _ = try await health.workout(.running, at: date(10, 20, 7), minutes: 30)
    _ = try await health.workout(.cycling, at: date(10, 20, 18), minutes: 60)
    _ = try await health.workout(.running, at: date(10, 18, 23, 30), minutes: 60)
    try await health.save(
      (0..<(60 * 60)).map { minute in
        SyntheticHealthKit.sample(
          heartRate, 100, at: date(10, 18, 12).addingTimeInterval(Double(minute) * 60))
      })
    let engine = HealthKitCardEngine(store: health.store)
    func counts(_ activities: String) async throws -> [Double] {
      let card = try CardSpec(
        inputJSON: Data(
          #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "workout", "activities": \#(activities)}}], "bucket": "day", "range": "W"}"#
            .utf8))
      return try await engine.data(
        CardRun(spec: card, range: .week, date: date(10, 20), now: date(10, 22), calendar: london)
      )
      .series[0].points.map(\.value)
    }
    // Monday Oct 19's 30 minutes past midnight, and Oct 20's run.
    #expect(try await counts("[37]") == [30, 30])
    #expect(try await counts("null") == [30, 90])
  }

  // MARK: - Recorded time zones

  /// A night slept in Tokyo (851-4176), seen from London, is Tokyo's, as on the Mac
  /// (`aNightFollowsTheZoneItWasRecordedIn`): 23:00 JST on Wednesday Oct 21 to 06:30 JST on the
  /// 22nd is Thursday's night, its 450 minutes asleep. On London's clock (15:00 to 22:30 BST) it
  /// would be a day's sleep on the 21st, and a night on the 22nd with only its 240 minutes of REM
  /// from 18:30. The heart rate has no zone, as a Watch's readings haven't.
  @Test
  func aNightFollowsTheZoneItWasRecordedIn() async throws {
    let health = try await SyntheticHealthKit.empty()
    func sleep(_ value: HKCategoryValueSleepAnalysis, _ start: Date, _ end: Date)
      -> HKCategorySample
    {
      SyntheticHealthKit.sleep(value, start, end, timeZone: "Asia/Tokyo")
    }
    var samples: [HKSample] = [
      sleep(.inBed, date(10, 21, 14, 45), date(10, 21, 22, 40)),
      sleep(.asleepCore, date(10, 21, 15), date(10, 21, 18, 30)),
      sleep(.asleepREM, date(10, 21, 18, 30), date(10, 21, 22, 30)),
    ]
    samples += (0..<450).map { minute in
      SyntheticHealthKit.sample(
        heartRate, 50, at: date(10, 21, 15).addingTimeInterval(Double(minute) * 60))
    }
    try await health.save(samples)
    let card = try CardSpec(
      inputJSON: Data(
        #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "asleep"}}], "bucket": "night", "range": "W"}"#
          .utf8))
    let data = try await HealthKitCardEngine(store: health.store).data(
      CardRun(spec: card, range: .week, date: date(10, 20), now: date(10, 26), calendar: london))
    #expect(data.series[0].points.map(\.start) == [date(10, 22)])
    #expect(data.series[0].points.map(\.value) == [450])
  }

  /// A sleep record's zone is its `HKMetadataKeyTimeZone` when that's a zone's name, old aliases
  /// included, as the Mac reads it (`onlyAZonesNameIsAZone`): `GMT+9`, which HealthKit takes but
  /// the tools don't, or no zone loses only the zone, and the record stays. HealthKit itself
  /// refuses to make a sample whose zone is a UTC offset (`+09:00`), in the wrong case or blank.
  /// The name stays as written (851-4177): Foundation's zone for `UTC` is `GMT`.
  @Test
  func onlyAZonesNameIsAZone() async throws {
    let health = try await SyntheticHealthKit.empty()
    let zones: [String?] = ["Europe/Kyiv", "Europe/Kiev", nil, "GMT+9", "US/Pacific", "UTC"]
    try await health.save(
      zones.enumerated().map { index, zone in
        SyntheticHealthKit.sleep(
          .asleepCore, date(10, 10, index), date(10, 10, index, 30), timeZone: zone)
      })
    let day = [date(10, 10), date(10, 11)].map { Int($0.timeIntervalSince1970 * 1000) }
    let records = try await HealthKitCardEngine(store: health.store).sleepRecords(
      overlapping: day[0]..<day[1])
    #expect(
      records.map(\.timeZone?.identifier)
        == ["Europe/Kyiv", "Europe/Kiev", nil, nil, "US/Pacific", "GMT"])
    #expect(
      records.map(\.timeZoneName) == ["Europe/Kyiv", "Europe/Kiev", nil, nil, "US/Pacific", "UTC"])
  }

  // MARK: - Support

  /// The points that differ, for a failure's message.
  private func differences(_ data: CardData, _ expected: CardData) -> String {
    var lines: [String] = []
    for (series, other) in zip(data.series, expected.series) {
      let starts = Set(series.points.map(\.start)).union(other.points.map(\.start)).sorted()
      for start in starts {
        let a = series.points.first { $0.start == start }
        let b = other.points.first { $0.start == start }
        if a != b {
          lines.append(
            "\(series.id) \(start): \(a.map { "\($0.value) (\($0.readings ?? -1))" } ?? "none") vs \(b.map { "\($0.value) (\($0.readings ?? -1))" } ?? "none")"
          )
        }
      }
    }
    if data.summary != expected.summary {
      lines.append(
        "summary: \(String(describing: data.summary)) vs \(String(describing: expected.summary))")
    }
    return lines.joined(separator: "; ")
  }

  private static func device(_ model: String) -> HKDevice {
    HKDevice(
      name: model, manufacturer: "Apple Inc.", model: model, hardwareVersion: nil,
      firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
  }
}
