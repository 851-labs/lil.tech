public import Foundation
public import GRDB
public import HealthCards
import HealthCatalog
import SQLite3
import SQLiteData

// The Mac's card engine (docs/decisions/cards.md, The Mac): cards' shared core (`CardRun`) over
// this database. Totals come from `cumulativeTotals`, as Metric Detail's do, and readings from the
// samples' (type, startDate) index. Sleep windows read the period's sleep records (grouped into
// nights as Sleep's page groups them) and workout windows its workouts, then the readings in their
// stretches only (851-3196).

extension HealthDatabase {
  /// Every table a card reads, which Summary follows to show its headlines (851-3237): a card
  /// query that reads another must add it here, or Summary misses its changes.
  /// `CardQueriesTests.cardTablesCoverWhatHeadlinesRead` checks it.
  public static let cardTables: [any DatabaseRegionConvertible] = [
    GRDB.Table<Row>(HealthSample.tableName),
    GRDB.Table<Row>(HealthStatistic.tableName),
    GRDB.Table<Row>(HealthStatisticsDevice.tableName),
    GRDB.Table<Row>(HealthProvenance.tableName),
    GRDB.Table<Row>(HealthWorkout.tableName),
    GRDB.Table<Row>(HealthQuantitySeries.tableName),
  ]

  /// A card over the period of `range` containing `date`.
  public static func cardData(
    _ spec: CardSpec, range: CardRange, date: Date, now: Date, calendar: Calendar,
    _ db: Database
  ) throws -> CardData {
    try cardData(
      CardRun(spec: spec, range: range, date: date, now: now, calendar: calendar), now: now, db)
  }

  /// A run's data, fetched from this database.
  public static func cardData(_ run: CardRun, now: Date, _ db: Database) throws -> CardData {
    var run = run
    if !run.windowFetches.isEmpty {
      run = run.windowed(
        try run.windowFetches.map { fetch in
          switch fetch {
          case .sleep(let range): .sleep(try sleepRecords(in: range, db))
          case .workouts(let range): .workouts(try cardWorkouts(in: range, db))
          }
        })
    }
    return run.compute(
      try run.fetches.map { fetch in
        switch fetch.kind {
        case .totals(let range, let grain):
          let totals = try cumulativeTotals(
            of: fetch.type, in: range, by: grain.statisticsPeriod, now: now,
            calendar: run.calendar, db)
          return .totals(totals.map { CardTotal(start: $0.start, sum: $0.sum) })
        case .readings(let range, let filter, let needsSampleIDs):
          return .readings(
            try cardReadings(
              of: fetch.type, in: range, filter: filter, sampleIDs: needsSampleIDs, db))
        case .stretchReadings(let stretches, let filter, let needsSampleIDs):
          return .readings(
            try cardReadings(
              of: fetch.type, in: stretches, filter: filter, sampleIDs: needsSampleIDs, db))
        }
      })
  }

  /// Workouts of every activity that end after `range` starts and start before it ends (Unix
  /// milliseconds), from every source, with whether each was indoors, as the `workouts` tools say.
  static func cardWorkouts(in range: Range<Int>, _ db: Database) throws -> [CardWorkout] {
    let (lower, upper) = (range.lowerBound, range.upperBound)
    return
      try HealthWorkout
      .where { $0.startDate < upper && $0.endDate > lower }
      .order(by: \.startDate)
      .select { ($0.startDate, $0.endDate, $0.activityType, $0.metadata, $0.activities) }
      .fetchAll(db)
      .map { start, end, activityType, metadata, activities in
        CardWorkout(
          start: start, end: end, activityType: activityType,
          indoor: HealthWorkout.indoor(metadata: metadata, activities: activities))
      }
  }

  /// A type's readings starting in one of `stretches` (in order and apart), oldest first, that
  /// match `filter`: a range of the index for each. Reading a night's stretches asleep as one
  /// range, and dropping the minutes awake between them, was no faster (851-3196). A series near
  /// two stretches is parsed once (851-4172).
  static func cardReadings(
    of type: String, in stretches: [CardStretch], filter: CardSpec.Filter?, sampleIDs: Bool,
    _ db: Database
  ) throws -> [CardReading] {
    var parsed: [String: CardSeries.Series] = [:]
    return try stretches.flatMap { stretch in
      let range = stretch.start..<stretch.end
      return try cardReadings(
        of: type, in: range, filter: filter, sampleIDs: sampleIDs,
        series: try cardSeries(of: type, for: range, filter, parsed: &parsed, db), db)
    }
  }

  /// What a card's Summary row shows (`CardHeadline`), from data started by `now`; `nil` for No
  /// Data.
  public static func cardHeadline(
    _ spec: CardSpec, now: Date, calendar: Calendar, _ db: Database
  ) throws -> CardHeadline? {
    func run(endingOn date: Date) throws -> CardData {
      try cardData(CardRun(headlineOf: spec, endingOn: date, calendar: calendar), now: now, db)
    }
    switch spec.headlineLookup {
    case nil:
      return nil
    case .latestReading(let type):
      guard let reading = try latestCardReading(of: type, startedBy: now, db) else { return nil }
      let date = Date(unixMilliseconds: reading.start)
      return CardHeadline(
        value: reading.value, date: date, kind: .reading, data: try run(endingOn: date))
    case .latestData(let type):
      guard let date = try latestPeriodDate(of: type, by: now, calendar: calendar, db) else {
        return nil
      }
      return CardHeadline(latestBucketOf: try run(endingOn: date))
    case .search:
      for end in CardHeadline.searchEnds(for: spec, now: now, calendar: calendar) {
        if let headline = CardHeadline(latestBucketOf: try run(endingOn: end)) { return headline }
      }
      return nil
    }
  }

  /// A type's latest reading started by `now`: its latest sample's, or a series' latest value
  /// (`CardSeries.latestReading`, 851-4172).
  static func latestCardReading(of type: String, startedBy now: Date, _ db: Database) throws
    -> CardReading?
  {
    guard let sample = try latestSample(of: type, startedBy: now, db), let value = sample.value
    else { return nil }
    let upper = now.unixMilliseconds + 1
    var parsed: [String: CardSeries.Series] = [:]
    let series = try cardSeries(
      of: type, for: sample.startDate..<upper, nil, parsed: &parsed, db)
    return CardSeries.latestReading(
      sample: CardReading(
        start: sample.startDate, end: sample.endDate, value: value,
        source: sample.sourceBundleID, sampleID: sample.id),
      sampleIsSeries: series.contains { $0.sample.sampleID == sample.id },
      values: CardSeries.readings(of: series, in: sample.startDate..<upper).flatMap(\.self))
  }

  /// When the period of `range` a card's page and the editor's preview open on is from
  /// (851-3188, 851-3987): its headline's, as its Summary row and the iPhone's page find it, so
  /// they agree. `nil` for No Data: the current period. Without a window, filter or formula
  /// that's the lead type's latest data (`latestPeriodDate`, which the headline's run ends on),
  /// one seek of an index, cheap enough for a page to read before it first draws. With one, the
  /// lead type's latest data may have none of the card's readings, so it's the headline's bucket,
  /// from its search (up to 8 runs of a card: off the main thread), and when that bucket
  /// straddles two periods, the later one if it has the bucket's point
  /// (`CardHeadline.openingDates`).
  public static func cardOpeningDate(
    _ spec: CardSpec, range: CardRange, now: Date, calendar: Calendar, _ db: Database
  ) throws -> Date? {
    switch spec.headlineLookup {
    case nil:
      return nil
    case .latestReading(let type), .latestData(let type):
      return try latestPeriodDate(of: type, by: now, calendar: calendar, db)
    case .search:
      guard let headline = try cardHeadline(spec, now: now, calendar: calendar, db) else {
        return nil
      }
      let dates = CardHeadline.openingDates(
        forBucketAt: headline.date, grain: headline.data.grain, range: range, now: now,
        calendar: calendar)
      for date in dates.dropLast() {
        let data = try cardData(
          spec, range: range, date: date, now: now, calendar: calendar, db)
        if data.leadPoints.contains(where: { $0.start == headline.date }) { return date }
      }
      return dates.last
    }
  }

  /// A type's readings starting in `range` (Unix milliseconds), oldest first, that match
  /// `filter`: a range of the (type, startDate) index, with a series' values as readings in place
  /// of its sample (`CardSeries`, 851-4172), from a range of the series' (type, startDate) index.
  /// A covering index would save SQLite about 40% of its part, but would copy every sample's type
  /// and source again (851-3195).
  static func cardReadings(
    of type: String, in range: Range<Int>, filter: CardSpec.Filter?, sampleIDs: Bool,
    _ db: Database
  ) throws -> [CardReading] {
    var parsed: [String: CardSeries.Series] = [:]
    return try cardReadings(
      of: type, in: range, filter: filter, sampleIDs: sampleIDs,
      series: try cardSeries(of: type, for: range, filter, parsed: &parsed, db), db)
  }

  /// The same, with the series that can have readings in `range` read already.
  private static func cardReadings(
    of type: String, in range: Range<Int>, filter: CardSpec.Filter?, sampleIDs: Bool,
    series: [CardSeries.Series], _ db: Database
  ) throws -> [CardReading] {
    // The series starting in the range, whose samples are read as their values instead. Without
    // any, the samples are read as before.
    var leavingOut: [Int: [String]] = [:]
    for series in series where range.contains(series.sample.start) {
      leavingOut[series.sample.start, default: []].append(series.sample.sampleID)
    }
    let singles = try singleReadings(
      of: type, in: range, filter: filter, sampleIDs: sampleIDs, leavingOut: leavingOut, db)
    guard !series.isEmpty else { return singles }
    return CardSeries.merged(singles, CardSeries.readings(of: series, in: range))
  }

  /// The series of `type` that can have values in `range`, by start then ID, whose samples
  /// match `filter`: those starting a day before it or later (`CardSeries.starts(for:)`), and
  /// before its end, whose samples end in it or later, since a series' values are within its
  /// sample. A range of the series' (type, startDate) index. A series whose values don't parse is
  /// read as its sample. `parsed`: series parsed already, by ID, which are used again.
  static func cardSeries(
    of type: String, for range: Range<Int>, _ filter: CardSpec.Filter?,
    parsed: inout [String: CardSeries.Series], _ db: Database
  ) throws -> [CardSeries.Series] {
    let (join, conditions, arguments) = sampleConditions(filter)
    let starts = CardSeries.starts(for: range)
    let sql = """
      SELECT "q"."id", "s"."startDate", "s"."endDate", "s"."value", "s"."sourceBundleID",
        "q"."startDate", "q"."times", "q"."durations", "q"."values"
      FROM "healthQuantitySeries" AS "q"
      JOIN "healthSamples" AS "s" ON "s"."id" = "q"."id" \(join)
      WHERE "q"."type" = ? AND "q"."startDate" >= ? AND "q"."startDate" < ?
        AND "q"."values" IS NOT NULL AND "s"."value" IS NOT NULL AND "s"."endDate" >= ?
        \(conditions.map { "AND \($0)" }.joined(separator: " "))
      ORDER BY "q"."startDate", "q"."id"
      """
    let statement = try db.cachedStatement(sql: sql)
    let ids = try String.fetchCursor(
      statement,
      arguments: [type, starts.lowerBound, starts.upperBound, range.lowerBound] + arguments)
    let raw = statement.sqliteStatement
    var series: [CardSeries.Series] = []
    while let id = try ids.next() {
      if let known = parsed[id] {
        series.append(known)
        continue
      }
      let read = CardSeries.Series(
        sample: CardReading(
          start: Int(sqlite3_column_int64(raw, 1)), end: Int(sqlite3_column_int64(raw, 2)),
          value: sqlite3_column_double(raw, 3),
          source: String(cString: sqlite3_column_text(raw, 4)), sampleID: id),
        start: Int(sqlite3_column_int64(raw, 5)),
        times: numbers(sqlite3_column_text(raw, 6), sqlite3_column_bytes(raw, 6)),
        durations: numbers(sqlite3_column_text(raw, 7), sqlite3_column_bytes(raw, 7)),
        values: numbers(sqlite3_column_text(raw, 8), sqlite3_column_bytes(raw, 8)))
      parsed[id] = read
      series.append(read)
    }
    return series
  }

  /// A JSON array of numbers (`count` bytes of UTF-8), as `health_quantity_series` keeps a
  /// series' times, durations and values; empty if it isn't one (then the series' arrays don't
  /// line up, and it's read as its sample). A year of a run a day's series is 600,000 numbers, so
  /// it's read from the bytes: a number of at most 15 digits without an exponent, as uploads
  /// write them (`125`, `0.005`), is its digits divided by a power of ten, which is exact
  /// (Clinger's fast path); others go through `Double(_:)`. Both take the C locale's decimal
  /// point, whatever the process's. `JSONDecoder` was several times slower.
  static func numbers(_ text: UnsafePointer<UInt8>?, _ count: Int32) -> [Double] {
    guard let text else { return [] }
    let bytes = UnsafeBufferPointer(start: text, count: Int(count))
    var index = 0
    func skipSpaces() {
      while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }
    skipSpaces()
    guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return [] }
    index += 1
    skipSpaces()
    var numbers: [Double] = []
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") { return numbers }
    while index < bytes.count {
      let start = index
      while index < bytes.count,
        ![UInt8(ascii: ","), UInt8(ascii: "]"), 0x20, 0x0A, 0x0D, 0x09]
          .contains(bytes[index])
      {
        index += 1
      }
      guard let number = Self.number(UnsafeBufferPointer(rebasing: bytes[start..<index])) else {
        return []
      }
      numbers.append(number)
      skipSpaces()
      guard index < bytes.count else { return [] }
      if bytes[index] == UInt8(ascii: "]") { return numbers }
      guard bytes[index] == UInt8(ascii: ",") else { return [] }
      index += 1
      skipSpaces()
    }
    return []
  }

  private static let powersOfTen: [Double] = (0...22).map { pow(10, Double($0)) }

  /// One JSON number's bytes.
  private static func number(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
    var index = 0
    let negative = index < bytes.count && bytes[index] == UInt8(ascii: "-")
    if negative { index += 1 }
    var mantissa: UInt64 = 0
    var digits = 0
    var decimals = 0
    var point = false
    var fast = index < bytes.count
    while index < bytes.count, fast {
      let byte = bytes[index]
      if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
        // Leading zeros don't count towards the 15.
        if mantissa > 0 || byte != UInt8(ascii: "0") { digits += 1 }
        mantissa = mantissa &* 10 &+ UInt64(byte - UInt8(ascii: "0"))
        if point { decimals += 1 }
      } else if byte == UInt8(ascii: "."), !point {
        point = true
      } else {
        fast = false
      }
      index += 1
    }
    if fast, digits <= 15, decimals <= 22, bytes.last != UInt8(ascii: ".") {
      let value = Double(mantissa) / powersOfTen[decimals]
      return negative ? -value : value
    }
    return Double(String(decoding: bytes, as: UTF8.self))
  }

  /// The samples' readings in `range`, but those of series in `leavingOut` (their IDs by their
  /// starts), which are read as their values instead. A row starting with one of them has its ID
  /// read and compared, rather than every row being looked up in the series (`NOT IN`), which
  /// took a year's card from 145 ms of fetching to 300 on a year of a run a day's series.
  private static func singleReadings(
    of type: String, in range: Range<Int>, filter: CardSpec.Filter?, sampleIDs: Bool,
    leavingOut: [Int: [String]], _ db: Database
  ) throws -> [CardReading] {
    var (join, conditions, filterArguments) = sampleConditions(filter)
    conditions =
      [
        #""s"."type" = ?"#, #""s"."startDate" >= ?"#, #""s"."startDate" < ?"#,
        #""s"."value" IS NOT NULL"#,
      ] + conditions
    var arguments: StatementArguments = [type, range.lowerBound, range.upperBound]
    arguments += filterArguments
    let readsIDs = sampleIDs || !leavingOut.isEmpty
    let sql = """
      SELECT "s"."startDate", "s"."endDate", "s"."value", "s"."sourceBundleID"\
      \(readsIDs ? #", "s"."id""# : "")
      FROM "healthSamples" AS "s" \(join)
      WHERE \(conditions.joined(separator: " AND "))
      ORDER BY "s"."startDate"
      """
    // Read by column from the statement, with one string per run of a source's rows rather than
    // one a row: of a year of readings a minute, 42 ms on top of SQLite's own reading, against 73
    // ms for a `Row` each (`CardQueriesBenchmark`). Sharing the string also makes the weights'
    // comparisons of sources a comparison of pointers.
    var readings: [CardReading] = []
    let statement = try db.cachedStatement(sql: sql)
    let starts = try Int.fetchCursor(statement, arguments: arguments)
    let raw = statement.sqliteStatement
    var source = (bytes: [UInt8](), string: "")
    while let start = try starts.next() {
      if let series = leavingOut[start], let text = sqlite3_column_text(raw, 4),
        series.contains(String(cString: text))
      {
        continue
      }
      // The text first, then its length, as SQLite recommends.
      let text = sqlite3_column_text(raw, 3)
      let count = Int(sqlite3_column_bytes(raw, 3))
      if let text, count != source.bytes.count || memcmp(text, source.bytes, count) != 0 {
        let bytes = [UInt8](UnsafeBufferPointer(start: text, count: count))
        source = (bytes, String(decoding: bytes, as: UTF8.self))
      }
      var sampleID = ""
      if sampleIDs, let text = sqlite3_column_text(raw, 4) {
        sampleID = String(cString: text)
      }
      readings.append(
        CardReading(
          start: start, end: Int(sqlite3_column_int64(raw, 1)),
          value: sqlite3_column_double(raw, 2), source: source.string, sampleID: sampleID))
    }
    return readings
  }

  /// What `filter` asks of a sample (`"s"`): its source, and its device's model, the sample's own
  /// or its provenance's (851-2674). JSON that doesn't parse matches no model, rather than failing
  /// the card.
  private static func sampleConditions(_ filter: CardSpec.Filter?)
    -> (join: String, conditions: [String], arguments: StatementArguments)
  {
    var conditions: [String] = []
    var arguments: StatementArguments = []
    var join = ""
    if let sources = filter?.sources {
      conditions.append(#""s"."sourceBundleID" IN (\#(placeholders(sources.count)))"#)
      arguments += StatementArguments(sources)
    }
    if let models = filter?.deviceModels {
      join = #"LEFT JOIN "healthProvenances" AS "p" ON "p"."id" = "s"."provenance""#
      let device = #"coalesce("s"."device", "p"."device")"#
      conditions.append(
        #"CASE WHEN json_valid(\#(device)) THEN json_extract(\#(device), '$.model') END IN (\#(placeholders(models.count)))"#
      )
      arguments += StatementArguments(models)
    }
    return (join, conditions, arguments)
  }

  private static func placeholders(_ count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
  }
}

extension CardGrain {
  var statisticsPeriod: StatisticsPeriod {
    switch self {
    case .hour: .hour
    case .day: .day
    case .week: .week
    case .month: .month
    }
  }
}
