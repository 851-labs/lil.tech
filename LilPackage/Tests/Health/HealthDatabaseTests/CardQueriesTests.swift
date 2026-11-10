import Dependencies
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
  /// Summary follows the tables cards read (`cardTables`, 851-3237): every table a headline reads
  /// is one of them, for the seed, the design's example cards, and a device filter and a workout
  /// window, which read tables the others don't.
  @Test
  func cardTablesCoverWhatHeadlinesRead() async throws {
    let specs =
      HealthCards.welcomeSeed.map(\.spec) + exampleCards.compactMap(\.spec) + [
        try spec(
          #"{"version": 1, "display": {"name": "Watch"}, "series": [{"type": "Heart Rate", "filter": {"deviceModels": ["Watch"]}}], "range": "M"}"#
        ),
        try spec(
          #"{"version": 1, "display": {"name": "Runs"}, "series": [{"type": "Heart Rate", "window": {"kind": "workout", "activities": [37]}}], "range": "M"}"#
        ),
      ]
    let declared = try await exampleCardsDatabase.read { db in
      try HealthDatabase.cardTables.reduce(DatabaseRegion()) { $0.union(try $1.databaseRegion(db)) }
    }
    for spec in specs {
      let read = LockIsolated(DatabaseRegion())
      let observation = ValueObservation.tracking { db in
        try HealthDatabase.cardHeadline(spec, now: previewNow, calendar: previewCalendar, db)
      }
      .handleEvents(willTrackRegion: { region in read.withValue { $0.formUnion(region) } })
      for try await _ in observation.values(in: exampleCardsDatabase) { break }
      #expect(!read.value.isEmpty, "\(spec.display.name)")
      #expect(
        declared.union(read.value) == declared, "\(spec.display.name) reads \(read.value)")
    }
  }

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
    // The average of the days' first weigh-ins (851-3244).
    #expect(data.summary == CardSummary(kind: .average, value: 71))
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

  /// A card's page opens on its headline's period (851-3987): for heart rate before sleep, the
  /// month of its latest night, not of heart rate's latest reading, which has no night in it. A
  /// card without a window opens on its type's latest data, as Metric Detail does.
  @Test
  func aWindowedCardOpensOnItsHeadlinesPeriod() throws {
    try database.write { db in
      try HealthSample.insert {
        night(21)
        for minute in -65..<(-60) {
          sample(heartRate, date(10, 21).addingTimeInterval(Double(minute) * 60), 60)
        }
        // November's readings, with no sleep.
        sample(heartRate, date(11, 2, 9), 70)
        sample(heartRate, date(11, 3, 9), 72)
      }
      .execute(db)
    }
    func opening(_ series: String, bucket: String = "night") throws -> Date? {
      let card = try spec(
        #"{"version": 1, "display": {"name": "Card"}, "series": [\#(series)], "bucket": "\#(bucket)", "range": "M"}"#
      )
      return try database.read { db in
        try HealthDatabase.cardOpeningDate(
          card, range: .month, now: date(11, 3, 12), calendar: calendar, db)
      }
    }
    #expect(
      try opening(#"{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}"#)
        == date(10, 21))
    #expect(try opening(#"{"type": "Heart Rate"}"#, bucket: "auto") == date(11, 3, 9))
    #expect(
      try opening(#"{"type": "Heart Rate", "aggregation": "max"}"#, bucket: "day")
        == date(11, 3, 9))
    // No Data opens the current period.
    #expect(
      try opening(#"{"type": "Heart Rate", "window": {"kind": "afterWaking", "minutes": 5}}"#)
        == nil)
  }

  /// A weekly card whose latest week straddles two months opens on the month with its readings
  /// (851-3987): October's for nights in October (the week of Monday Sep 28), and September's for
  /// nights in September only, though both are that week's point.
  @Test(arguments: [(nights: [1, 2], month: 10), (nights: [0], month: 9)])
  func aWeekAcrossAMonthsEndOpensOnTheMonthWithItsReadings(nights: [Int], month: Int) throws {
    try database.write { db in
      try HealthSample.insert {
        for day in nights {
          night(day)
          // A reading every 10 minutes while asleep, from midnight.
          for minute in stride(from: 0, to: 300, by: 10) {
            sample(heartRate, date(10, day).addingTimeInterval(Double(minute) * 60), 55)
          }
        }
      }
      .execute(db)
    }
    let card = try spec(
      #"{"version": 1, "display": {"name": "Card"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}}], "bucket": "week", "range": "M"}"#
    )
    let now = date(10, 10, 12)
    let opening = try #require(
      try database.read { db in
        try HealthDatabase.cardOpeningDate(
          card, range: .month, now: now, calendar: calendar, db)
      })
    #expect(calendar.component(.month, from: opening) == month)
    // The month opened on has the week's point.
    let data = try database.read { db in
      try HealthDatabase.cardData(
        card, range: .month, date: opening, now: now, calendar: calendar, db)
    }
    #expect(data.leadPoints.map(\.start) == [date(9, 28)])
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

  /// A series (851-4172): a sample with its values in `healthQuantitySeries`, instants at
  /// `minutes` past `start`.
  private func series(
    _ type: String, _ start: Date, minutes: [Double], values: [Double],
    source: String = "com.apple.health.watch", device: String? = nil, uploadedValues: Bool = true
  ) -> (HealthSample, HealthQuantitySeries) {
    let id = UUID().uuidString.lowercased()
    let seconds = minutes.map { $0 * 60 }
    func json(_ numbers: [Double]) -> String {
      "[" + numbers.map { "\($0)" }.joined(separator: ",") + "]"
    }
    return (
      HealthSample(
        id: id, type: type, startDate: start.unixMilliseconds,
        endDate: start.addingTimeInterval(seconds.last ?? 0).unixMilliseconds,
        value: values.reduce(0, +) / Double(values.count), unit: "x", sourceName: "Test",
        sourceBundleID: source, device: device),
      HealthQuantitySeries(
        id: id, type: type, startDate: start.unixMilliseconds, count: values.count,
        times: uploadedValues ? json(seconds) : nil,
        durations: uploadedValues ? json(seconds.map { _ in 0 }) : nil,
        values: uploadedValues ? json(values) : nil, minimum: values.min(),
        maximum: values.max(), mostRecent: values.last)
    )
  }

  private func insert(_ series: [(HealthSample, HealthQuantitySeries)], _ db: Database) throws {
    try HealthSample.insert { series.map(\.0) }.execute(db)
    try HealthQuantitySeries.insert { series.map(\.1) }.execute(db)
  }

  /// A series is read as its values (851-4172): each a reading at its own time, with its
  /// sample's source and device, so they fall in their own hours, count one each, and weigh
  /// until the source's next. One that started before the period has its values in it read,
  /// and one uploaded without its values is one reading, its sample.
  @Test
  func seriesAreReadAsTheirValues() throws {
    let watch = #"{"name":"Apple Watch","model":"Watch"}"#
    try database.write { db in
      try insert(
        [
          // From 23:30 the day before: its last two values are in the period.
          series(
            heartRate, date(10, 19, 23.5), minutes: [0, 15, 30, 45], values: [50, 52, 54, 56],
            device: watch),
          // A run, across an hour's end.
          series(
            heartRate, date(10, 20, 9.75), minutes: [0, 10, 20], values: [120, 150, 130],
            device: watch),
          series(
            heartRate, date(10, 20, 14), minutes: [0, 1], values: [70, 90], device: watch,
            uploadedValues: false),
        ], db)
      try HealthSample.insert {
        sample(heartRate, date(10, 20, 10.5), 100, source: "com.example.strap")
      }
      .execute(db)
    }
    func points(_ series: String, filter: String = "null") throws -> [CardPoint] {
      let card = try spec(
        #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "Heart Rate", \#(series), "filter": \#(filter)}], "bucket": "hour", "range": "D"}"#
      )
      return try database.read { db in
        try HealthDatabase.cardData(
          card, range: .day, date: date(10, 20), now: date(10, 21), calendar: calendar, db)
      }
      .series[0].points
    }
    // 00:00: the series from the day before's last two; 09:00 and 10:00: the run's values, and
    // the strap's; 14:00: the series without its values, as its sample.
    #expect(try points(#""aggregation": "count""#).map(\.value) == [2, 2, 2, 1])
    #expect(try points(#""aggregation": "max""#).map(\.value) == [56, 150, 130, 80])
    #expect(
      try points(#""aggregation": "count""#, filter: #"{"deviceModels": ["Watch"]}"#)
        .map(\.value) == [2, 2, 1, 1])
    // 09:00: 120 and 150 for 10 minutes each. 10:00: 130 until the source's next reading,
    // 14:00's (capped: an hour), and the strap's 100, its last, for its own minute.
    let averages = try points(#""aggregation": "avg""#).map(\.value)
    #expect(averages[1] == 135)
    #expect(abs(averages[2] - (130 * 3600 + 100 * 60) / 3660) < 1e-9)
  }

  /// Series' JSON arrays are read as JSON reads them, to the bit, quickly where it can.
  @Test
  func seriesArraysParseAsJSON() throws {
    func numbers(_ json: String) -> [Double] {
      json.withCString { text in
        text.withMemoryRebound(to: UInt8.self, capacity: json.utf8.count) {
          HealthDatabase.numbers($0, Int32(json.utf8.count))
        }
      }
    }
    let json =
      "[0, 0.005, 125, -3.25, 72.499999999999, 1e-7, 1.5E3, 0.1, 123456789012345678, 0.30000000000000004]"
    let expected = try JSONDecoder().decode([Double].self, from: Data(json.utf8))
    #expect(numbers(json) == expected)
    #expect(numbers("[]") == [])
    #expect(numbers(" [ 1 ,2 ] ") == [1, 2])
    for broken in ["", "[", "[1,]", "[1 2]", "[a]", "{}"] {
      #expect(numbers(broken) == [], "\(broken)")
    }
  }

  /// A Summary row's latest reading is a series' latest value started by then, from any source,
  /// not its sample's, which is the whole series' (851-4172).
  @Test
  func aSeriesLatestValueIsTheLatestReading() throws {
    try database.write { db in
      try insert(
        [
          series(
            heartRate, date(10, 20, 9), minutes: [0, 30, 60, 90], values: [110, 140, 120, 90])
        ],
        db)
      try HealthSample.insert {
        sample(heartRate, date(10, 20, 10.25), 75, source: "com.example.strap")
      }
      .execute(db)
    }
    let card = try spec(
      #"{"version": 1, "display": {"name": "HR"}, "series": [{"type": "Heart Rate"}]}"#)
    func headline(at now: Date) throws -> CardHeadline? {
      try database.read { db in
        try HealthDatabase.cardHeadline(card, now: now, calendar: calendar, db)
      }
    }
    // The strap's 75 at 10:15 is the latest sample, but the series' 90 at 10:30 is later.
    #expect(try headline(at: date(10, 20, 12))?.value == 90)
    #expect(try headline(at: date(10, 20, 12))?.date == date(10, 20, 10.5))
    #expect(try headline(at: date(10, 20, 10.3))?.value == 75)
    // The series is the latest sample: its latest value by then.
    #expect(try headline(at: date(10, 20, 9.75))?.value == 140)
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

  /// `withSeries` (851-4172): each day's run, 18:00 to 18:45, has heart rate as a Watch records
  /// a workout's, a series of a value every 5 seconds (540 values), in place of its minutes.
  @Test(arguments: [false, true])
  func aYearByTheDay(withSeries: Bool) throws {
    let url = URL.temporaryDirectory.appending(path: "card-benchmark-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try HealthDatabase.make(at: url)
    let start = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01 00:00 UTC
    let minutes = 525_600
    let upsert = PreparedUpsert<HealthSample>()
    let watch = "com.apple.health.81F3A2C4-5D6E-4F70-8A9B-0C1D2E3F4A5B"
    let watchDevice = #"{"name":"Apple Watch","model":"Watch"}"#
    func inRun(_ minute: Int) -> Bool {
      withSeries && (18 * 60..<18 * 60 + 45).contains(minute % 1440)
    }
    if withSeries {
      let seconds = Array(stride(from: 0, to: 45 * 60, by: 5))
      let times = "[" + seconds.map(String.init).joined(separator: ",") + "]"
      let durations = "[" + seconds.map { _ in "0" }.joined(separator: ",") + "]"
      let values = "[" + seconds.map { String(120 + ($0 * 7) % 50) }.joined(separator: ",") + "]"
      try database.write { db in
        for day in 0..<365 {
          let at = start.unixMilliseconds + (day * 1440 + 18 * 60) * 60_000
          let id = UUID().uuidString.lowercased()
          try upsert.execute(
            HealthSample(
              id: id, type: heartRate, startDate: at, endDate: at + (45 * 60 - 5) * 1000,
              value: 140, unit: "count/min", sourceName: "Apple Watch", sourceBundleID: watch,
              device: watchDevice),
            db)
          try HealthQuantitySeries.insert {
            HealthQuantitySeries(
              id: id, type: heartRate, startDate: at, count: seconds.count, times: times,
              durations: durations, values: values)
          }
          .execute(db)
        }
      }
    }
    for type in ["HKQuantityTypeIdentifierActiveEnergyBurned", heartRate] {
      try database.write { db in
        for minute in 0..<minutes where type != heartRate || !inRun(minute) {
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
    let seriesLookup = try median(database) { db in
      var parsed: [String: CardSeries.Series] = [:]
      _ = try HealthDatabase.cardSeries(
        of: heartRate, for: start.unixMilliseconds..<start.unixMilliseconds + 366 * 86_400_000,
        nil, parsed: &parsed, db)
    }
    print(
      "Series \(withSeries ? "with" : "without") series, reading the year's: \(seriesLookup) ms")
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
      print(
        "A year by the day, \(withSeries ? "with series, " : "")\(name): \(total) ms, of which fetching \(fetch) ms"
      )
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
      ("during cycling, by the day", #"{"kind": "workout", "activities": [13]}"#, "day"),
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
      print(
        "A year, \(withSeries ? "with series, " : "")heart rate \(name): \(total) ms, \(points) points"
      )
    }
  }
}
