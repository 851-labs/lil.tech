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
      try values(#"{"sources": ["com.example.strap", "com.apple.health.phone"]}"#) == [80, 100])
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
  }
}
