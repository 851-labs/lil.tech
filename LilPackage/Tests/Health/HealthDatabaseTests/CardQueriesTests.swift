import Foundation
import GRDB
import HealthCards
import HealthCatalog
import SQLiteData
import Testing

@testable import HealthDatabase

// The Mac's card engine on synthetic data only (AGENTS.md): the catalogs' demo database, and
// samples written here.

private let heartRate = "HKQuantityTypeIdentifierHeartRate"
private let bodyMass = "HKQuantityTypeIdentifierBodyMass"

private func spec(_ json: String) throws -> CardSpec {
  try CardSpec(inputJSON: Data(json.utf8))
}

@Suite
struct CardQueriesTests {
  /// The welcome seed's cards chart exactly as Metric Detail charts their types, to the bit, at
  /// every range, this period and the one before, on the catalogs' demo data.
  @Test(arguments: HealthCards.welcomeSeed)
  func seedCardsChartAsMetricDetail(card: SeedCard) throws {
    let type = try #require(card.spec.series[0].dataType)
    for range in ChartRange.allCases {
      for offset in [0, -1] {
        let date = range.interval(offset: offset, now: previewNow, calendar: previewCalendar).start
        let (chart, data) = try catalogDatabase.read { db in
          (
            try HealthDatabase.metricChart(
              of: type, range: range, offset: offset, now: previewNow, calendar: previewCalendar,
              db),
            try HealthDatabase.cardData(
              card.spec, range: range.card, date: date, now: previewNow, calendar: previewCalendar,
              db)
          )
        }
        let context = "\(card.seed) at \(range.rawValue), offset \(offset)"
        #expect(data.interval == chart.interval, "\(context)")
        #expect(!chart.points.isEmpty || offset != 0, "\(context) has demo data")
        #expect(
          data.series[0].points.map {
            [$0.start.timeIntervalSince1970, $0.value, $0.minimum, $0.maximum]
          }
            == chart.points.map {
              [$0.start.timeIntervalSince1970, $0.value, $0.minimum, $0.maximum]
            },
          "\(context)")
        #expect(data.summary == chart.summary.map { cardSummary($0, range) }, "\(context)")
      }
    }
  }

  /// Metric Detail's header as a card's: a total's average day is AVERAGE at W and M.
  private func cardSummary(_ summary: MetricChart.Summary, _ range: ChartRange) -> CardSummary {
    switch summary {
    case .total(let value): CardSummary(kind: .total, value: value)
    case .dailyAverage(let value):
      CardSummary(
        kind: range == .sixMonths || range == .year ? .dailyAverage : .average, value: value)
    case .range(let minimum, let maximum):
      CardSummary(kind: .range, value: nil, minimum: minimum, maximum: maximum)
    case .average(let value): CardSummary(kind: .average, value: value)
    case .averageDuration(let value): CardSummary(kind: .average, value: value)
    }
  }

  /// Summary's rows today: a day's total for steps, the latest reading for heart rate and weight.
  @Test
  func seedHeadlinesReadAsSummarysRows() throws {
    let (summaries, headlines) = try catalogDatabase.read { db in
      (
        try HealthDatabase.summaryMetrics(now: previewNow, calendar: previewCalendar, db),
        try HealthCards.welcomeSeed.map {
          try HealthDatabase.cardHeadline($0.spec, now: previewNow, calendar: previewCalendar, db)
        }
      )
    }
    for (summary, headline) in zip(summaries, headlines) {
      let headline = try #require(headline, "\(summary.id)")
      #expect(headline.value == summary.latestValue, "\(summary.id)")
      #expect(headline.date == summary.latestDate, "\(summary.id)")
      #expect(headline.kind == (summary.isDailyTotal ? .bucket : .reading), "\(summary.id)")
      #expect(headline.data.grain == .day)
      #expect(
        headline.data.series[0].points.map(\.start) == summary.days.map(\.day), "\(summary.id)")
    }
  }

  // MARK: - On samples of its own

  let database: any DatabaseWriter
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.firstWeekday = 2
    return calendar
  }()

  init() throws {
    database = try HealthDatabase.make()
  }

  private func date(_ month: Int, _ day: Int, _ hour: Double = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
      .addingTimeInterval(hour * 3600)
  }

  private func sample(
    _ type: String, _ start: Date, _ value: Double, source: String = "com.apple.health.watch",
    device: String? = nil, provenance: String? = nil, id: String? = nil
  ) -> HealthSample {
    HealthSample(
      id: id ?? UUID().uuidString.lowercased(), type: type, startDate: start.unixMilliseconds,
      endDate: start.unixMilliseconds + 60_000, value: value, unit: "x", sourceName: "Test",
      sourceBundleID: source, device: device, provenance: provenance)
  }

  @Test
  func filtersKeepTheSourcesAndDevicesGiven() throws {
    let phone = HealthProvenance(
      id: "0123456789abcdef0123456789abcdef", device: #"{"name":"iPhone","model":"iPhone"}"#)
    try database.write { db in
      try HealthProvenance.insert { phone }.execute(db)
      try HealthSample.insert {
        sample(heartRate, date(10, 20, 9), 60, device: #"{"name":"Apple Watch","model":"Watch"}"#)
        sample(
          heartRate, date(10, 20, 10), 80, source: "com.apple.health.phone", provenance: phone.id)
        sample(heartRate, date(10, 20, 11), 100, source: "com.example.strap")
        // A device that isn't JSON matches no model, and doesn't fail the card.
        sample(heartRate, date(10, 20, 12), 120, source: "com.example.strap", device: "{")
      }
      .execute(db)
    }
    func values(_ filter: String) throws -> [Double] {
      let card = try spec(
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "Heart Rate", "aggregation": "max", "filter": \#(filter)}], "bucket": "hour", "range": "D"}"#
      )
      return try database.read { db in
        try HealthDatabase.cardData(
          card, range: .day, date: date(10, 20), now: date(10, 21), calendar: calendar, db)
      }
      .series[0].points.map(\.value)
    }
    #expect(try values(#"{"deviceModels": ["Watch"]}"#) == [60])
    #expect(try values(#"{"deviceModels": ["iPhone", "Watch"]}"#) == [60, 80])
    #expect(
      try values(#"{"sources": ["com.example.strap", "com.apple.health.phone"]}"#) == [
        80, 100, 120,
      ])
    #expect(
      try values(#"{"sources": ["com.apple.health.phone"], "deviceModels": ["Watch"]}"#) == [])
  }

  /// Example 5 from the database: `first` reads sample IDs for its ties.
  @Test
  func morningWeight() throws {
    let card = try spec(
      #"{"version": 1, "display": {"name": "Morning Weight", "symbol": "scalemass.fill", "color": "purple"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#
    )
    try database.write { db in
      try HealthSample.insert {
        // Two at once on Oct 1: the smaller ID is first.
        sample(bodyMass, date(10, 1, 7.5), 71, id: "b")
        sample(bodyMass, date(10, 1, 7.5), 70, id: "a")
        sample(bodyMass, date(10, 1, 19), 75)
        // Only after noon on Oct 2.
        sample(bodyMass, date(10, 2, 12), 75)
        sample(bodyMass, date(10, 3, 11.9), 72)
        // In September, for the average.
        sample(bodyMass, date(9, 30, 8), 68)
      }
      .execute(db)
    }
    let data = try database.read { db in
      try HealthDatabase.cardData(
        card, range: .month, date: date(10, 20), now: date(10, 21), calendar: calendar, db)
    }
    #expect(data.series[0].points.map(\.value) == [70, 72])
    #expect(data.formulas[0].points.map(\.value) == [69, 70])
    #expect(data.summary == CardSummary(kind: .first, value: 70))
    // Its headline searches back from now for the latest day with a morning weigh-in.
    let headline = try database.read { db in
      try HealthDatabase.cardHeadline(card, now: date(10, 21, 9), calendar: calendar, db)
    }
    #expect(headline?.value == 72)
    #expect(headline?.date == date(10, 3))
    #expect(headline?.kind == .bucket)
  }

  // MARK: - Sleep and workout windows (851-3196)

  private func sleep(
    _ stage: SleepStage, _ start: Date, _ end: Date, source: String = "com.apple.health.watch"
  ) -> HealthSample {
    HealthSample(
      id: UUID().uuidString.lowercased(), type: HealthDatabase.sleepType,
      startDate: start.unixMilliseconds, endDate: end.unixMilliseconds,
      categoryValue: stage.rawValue, sourceName: "Test", sourceBundleID: source)
  }

  /// A Watch's night ending on Oct `day`: Core from 23:00, awake 01:00 to 01:10, REM to 06:30;
  /// an iPhone's shorter estimate of it; and a nap at 15:00 the next afternoon.
  private func night(_ day: Int) -> [HealthSample] {
    let midnight = date(10, day)
    func at(_ hours: Double) -> Date { midnight.addingTimeInterval(hours * 3600) }
    return [
      sleep(.inBed, at(-1.5), at(7)),
      sleep(.core, at(-1), at(1)),
      sleep(.awake, at(1), at(1 + 10 / 60)),
      sleep(.rem, at(1 + 10 / 60), at(6.5)),
      sleep(.asleep, at(0), at(5), source: "com.apple.health.phone"),
      sleep(.core, at(15), at(16)),
    ]
  }

  /// Examples 2 and 4 from the database: heart rate while asleep, and in the 5 minutes before
  /// falling asleep, per night, from Sleep's nights.
  @Test
  func sleepWindows() throws {
    try database.write { db in
      try HealthSample.insert {
        night(20) + night(21)
        // A reading a minute from 22:00 to 08:00: 50 asleep, 70 awake in the night, 80 up, and
        // 60 to 64 in the 5 minutes before sleep.
        for day in [20, 21] {
          for minute in -120..<480 {
            let value: Double =
              switch minute {
              case -65..<(-60): 60 + Double(minute + 65)
              case -60..<60, 70..<390: 50 + Double(day - 20)
              case 60..<70: 70
              default: 80
              }
            sample(heartRate, date(10, day).addingTimeInterval(Double(minute) * 60), value)
          }
        }
      }
      .execute(db)
    }
    func data(_ series: String) throws -> CardData {
      let card = try spec(
        #"{"version": 1, "display": {"name": "Card"}, "series": [\#(series)], "bucket": "night", "range": "W"}"#
      )
      return try database.read { db in
        try HealthDatabase.cardData(
          card, range: .week, date: date(10, 20), now: date(10, 22), calendar: calendar, db)
      }
    }
    let asleep = try data(#"{"type": "Heart Rate", "window": {"kind": "asleep"}}"#)
    #expect(asleep.series[0].points.map(\.start) == [date(10, 20), date(10, 21)])
    #expect(asleep.series[0].points.map(\.value) == [50, 51])
    // 120 minutes of Core and 320 of REM a night.
    #expect(asleep.series[0].points.map(\.readings) == [440, 440])
    let before = try data(
      #"{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}"#)
    #expect(before.series[0].points.map(\.value) == [62, 62])
    let after = try data(
      #"{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "afterWaking", "minutes": 20}}"#
    )
    #expect(after.series[0].points.map(\.value) == [20, 20])

    // Its headline searches back from now for the latest night.
    let card = try spec(
      #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "W"}"#
    )
    let headline = try database.read { db in
      try HealthDatabase.cardHeadline(card, now: date(10, 23, 9), calendar: calendar, db)
    }
    #expect(headline?.value == 51)
    #expect(headline?.date == date(10, 21))
  }

  /// Readings during workouts of the activities given, from the database's workouts.
  @Test
  func workoutWindows() throws {
    func workout(_ activity: Int, _ start: Date, minutes: Double) -> HealthWorkout {
      HealthWorkout(
        id: UUID().uuidString.lowercased(), activityType: activity,
        startDate: start.unixMilliseconds,
        endDate: start.addingTimeInterval(minutes * 60).unixMilliseconds, duration: minutes * 60,
        activities: "[]", events: "[]", statistics: "{}", sourceName: "Test",
        sourceBundleID: "com.apple.health.watch")
    }
    try database.write { db in
      try HealthWorkout.insert {
        workout(37, date(10, 20, 7), minutes: 30)
        workout(13, date(10, 20, 18), minutes: 60)
        // Started the evening before the period.
        workout(37, date(10, 18, 23.5), minutes: 60)
      }
      .execute(db)
      try HealthSample.insert {
        for minute in 0..<(60 * 60) {
          sample(heartRate, date(10, 18, 12).addingTimeInterval(Double(minute) * 60), 100)
        }
      }
      .execute(db)
    }
    func counts(_ activities: String) throws -> [Double] {
      let card = try spec(
        #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "aggregation": "count", "window": {"kind": "workout", "activities": \#(activities)}}], "bucket": "day", "range": "W"}"#
      )
      return try database.read { db in
        try HealthDatabase.cardData(
          card, range: .week, date: date(10, 20), now: date(10, 22), calendar: calendar, db)
      }
      .series[0].points.map(\.value)
    }
    // Monday Oct 19's 30 minutes past midnight, and Oct 20's run.
    #expect(try counts("[37]") == [30, 30])
    #expect(try counts("null") == [30, 90])
  }

  /// A night card's nights are Sleep's: on the catalogs' demo data, last night's heart rate while
  /// asleep is the Sleep page's highlight's.
  @Test
  func nightCardsReadSleepsNights() throws {
    func card(_ aggregation: String) throws -> CardSpec {
      try spec(
        #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "aggregation": "\#(aggregation)", "window": {"kind": "asleep"}}], "bucket": "night", "range": "M"}"#
      )
    }
    let (highlights, nights, lowest, highest) = try catalogDatabase.read { db in
      (
        try HealthDatabase.sleepHighlights(today: previewNow, calendar: previewCalendar, db),
        try HealthDatabase.sleepNights(
          endingOn: previewNow, count: 31, calendar: previewCalendar, db),
        try HealthDatabase.cardData(
          card("min"), range: .month, date: previewNow, now: previewNow,
          calendar: previewCalendar, db),
        try HealthDatabase.cardData(
          card("max"), range: .month, date: previewNow, now: previewNow,
          calendar: previewCalendar, db)
      )
    }
    let heartRate = try #require(highlights.heartRate)
    let today = previewCalendar.startOfDay(for: previewNow)
    #expect(lowest.series[0].points.last?.start == today)
    #expect(lowest.series[0].points.last?.value == heartRate.minimum)
    #expect(highest.series[0].points.last?.value == heartRate.maximum)
    // Every night with a point is one of Sleep's nights' sleep.
    let nightDays = Set(
      nights.filter { $0.nightBedtime(calendar: previewCalendar) != nil }.map(\.day))
    #expect(!lowest.series[0].points.isEmpty)
    #expect(lowest.series[0].points.allSatisfy { nightDays.contains($0.start) })
  }
}

/// A card over a year by the day, on a year of heart rate a minute (525,600 samples, far more than
/// a Watch records) among as many of another type's. It prints each card's CPU time, its fetch's,
/// and SQLite's alone reading the same rows, the floor. Run in Release with
/// `LIL_BENCHMARKS=1 swift test -c release --filter CardQueriesBenchmark`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIL_BENCHMARKS"] == "1"))
struct CardQueriesBenchmark {
  /// The thread's CPU time: unlike the wall clock, it doesn't count time other processes take.
  private func cpuMilliseconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1e6
  }

  /// The median of 5 runs of `body` in a read, in CPU milliseconds.
  private func median(_ database: any DatabaseWriter, _ body: (Database) throws -> Void) throws
    -> Double
  {
    var times: [Double] = []
    for _ in 0..<5 {
      times.append(
        try database.read { db in
          let before = cpuMilliseconds()
          try body(db)
          return cpuMilliseconds() - before
        })
    }
    return times.sorted()[2]
  }

  @Test
  func aYearByTheDay() throws {
    let url = URL.temporaryDirectory.appending(path: "card-benchmark-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try HealthDatabase.make(at: url)
    let start = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 00:00 UTC
    let minutes = 525_600
    let upsert = PreparedUpsert<HealthSample>()
    for type in ["HKQuantityTypeIdentifierActiveEnergyBurned", heartRate] {
      try database.write { db in
        for minute in 0..<minutes {
          let at = start.unixMilliseconds + minute * 60_000
          try upsert.execute(
            HealthSample(
              id: UUID().uuidString.lowercased(), type: type, startDate: at, endDate: at + 30_000,
              value: Double(50 + minute % 60), unit: "count/min", sourceName: "Apple Watch",
              sourceBundleID: "com.apple.health.81F3A2C4-5D6E-4F70-8A9B-0C1D2E3F4A5B",
              device: #"{"name":"Apple Watch","model":"Watch"}"#),
            db)
        }
      }
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let floor = try median(database) { db in
      _ = try Row.fetchOne(
        db,
        sql: """
          SELECT sum("endDate"), sum("value"), max("sourceBundleID") FROM "healthSamples"
          WHERE "type" = ? AND "startDate" >= ? AND "startDate" < ?
          """,
        arguments: [heartRate, start.unixMilliseconds, start.unixMilliseconds + 366 * 86_400_000])
    }
    print("SQLite reading a year's rows: \(floor) ms")
    let cards = [
      ("avg", #"{"type": "Heart Rate"}"#),
      (
        "max, of a device",
        #"{"type": "Heart Rate", "aggregation": "max", "filter": {"deviceModels": ["Watch"]}}"#
      ),
      (
        "first, before noon",
        #"{"type": "Heart Rate", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}}"#
      ),
    ]
    for (name, series) in cards {
      let card = try CardSpec(
        inputJSON: Data(
          #"{"version": 1, "display": {"name": "HR"}, "series": [\#(series)], "formulas": [{"kind": "movingAverage", "of": "a"}], "bucket": "day", "range": "Y"}"#
            .utf8))
      let run = CardRun(spec: card, range: .year, date: start, now: start, calendar: calendar)
      let fetch = try median(database) { db in
        for case .readings(let range, let filter, let ids) in run.fetches.map(\.kind) {
          _ = try HealthDatabase.cardReadings(
            of: heartRate, in: range, filter: filter, sampleIDs: ids, db)
        }
      }
      let total = try median(database) { db in
        let data = try HealthDatabase.cardData(run, now: start, db)
        #expect(data.series[0].points.count == 365)
      }
      print("A year by the day, \(name): \(total) ms, of which fetching \(fetch) ms")
    }

    // A year of a Watch's nights (10 records each, two awake in the night) and a 45-minute run
    // every day, for sleep and workout windows (851-3196).
    try database.write { db in
      let stages: [(SleepStage, Double, Double)] = [
        (.inBed, -1.5, 7.25), (.core, -1, 0.5), (.deep, 0.5, 1.5), (.core, 1.5, 2.5),
        (.rem, 2.5, 3.25), (.awake, 3.25, 3.33), (.core, 3.33, 5), (.rem, 5, 6),
        (.awake, 6, 6.08), (.core, 6.08, 7),
      ]
      for day in 0..<366 {
        let midnight = start.addingTimeInterval(Double(day) * 86_400)
        for (stage, from, to) in stages {
          try upsert.execute(
            HealthSample(
              id: UUID().uuidString.lowercased(), type: HealthDatabase.sleepType,
              startDate: midnight.addingTimeInterval(from * 3600).unixMilliseconds,
              endDate: midnight.addingTimeInterval(to * 3600).unixMilliseconds,
              categoryValue: stage.rawValue, sourceName: "Apple Watch",
              sourceBundleID: "com.apple.health.81F3A2C4-5D6E-4F70-8A9B-0C1D2E3F4A5B"),
            db)
        }
        let run = midnight.addingTimeInterval(18 * 3600)
        try HealthWorkout.insert {
          HealthWorkout(
            id: UUID().uuidString.lowercased(), activityType: day % 2 == 0 ? 37 : 13,
            startDate: run.unixMilliseconds, endDate: run.unixMilliseconds + 2_700_000,
            duration: 2700, activities: "[]", events: "[]", statistics: "{}",
            sourceName: "Apple Watch", sourceBundleID: "com.apple.health.watch")
        }
        .execute(db)
      }
    }
    let windowed = [
      ("asleep, by the night", #"{"kind": "asleep"}"#, "night"),
      ("5 minutes before sleep, by the night", #"{"kind": "beforeSleep", "minutes": 5}"#, "night"),
      ("during runs, by the day", #"{"kind": "workout", "activities": [37]}"#, "day"),
    ]
    for (name, window, bucket) in windowed {
      let card = try CardSpec(
        inputJSON: Data(
          #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "Heart Rate", "window": \#(window)}], "formulas": [{"kind": "movingAverage", "of": "a"}], "bucket": "\#(bucket)", "range": "Y"}"#
            .utf8))
      let run = CardRun(spec: card, range: .year, date: start, now: start, calendar: calendar)
      var points = 0
      let total = try median(database) { db in
        points = try HealthDatabase.cardData(run, now: start, db).series[0].points.count
      }
      #expect(points > 180)
      print("A year, heart rate \(name): \(total) ms, \(points) points")
    }
  }
}
