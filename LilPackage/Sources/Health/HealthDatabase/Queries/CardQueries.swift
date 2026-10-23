public import Foundation
import GRDB
public import HealthCards
import HealthCatalog
import SQLite3
public import SQLiteData

// The Mac's card engine (docs/decisions/cards.md, The Mac): cards' shared core (`CardRun`) over
// this database. Totals come from `cumulativeTotals`, as Metric Detail's do, and readings from the
// samples' (type, startDate) index.

extension HealthDatabase {
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
    run.compute(
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
        }
      })
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
      guard let sample = try latestSample(of: type, startedBy: now, db), let value = sample.value
      else { return nil }
      return CardHeadline(
        value: value, date: sample.start, kind: .reading, data: try run(endingOn: sample.start))
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

  /// A type's readings starting in `range` (Unix milliseconds), oldest first, that match
  /// `filter`: a range of the (type, startDate) index. A covering index would save SQLite about
  /// 40% of its part, but would copy every sample's type and source again (851-3195).
  static func cardReadings(
    of type: String, in range: Range<Int>, filter: CardSpec.Filter?, sampleIDs: Bool,
    _ db: Database
  ) throws -> [CardReading] {
    var conditions = [
      #""s"."type" = ?"#, #""s"."startDate" >= ?"#, #""s"."startDate" < ?"#,
      #""s"."value" IS NOT NULL"#,
    ]
    var arguments: StatementArguments = [type, range.lowerBound, range.upperBound]
    var join = ""
    if let sources = filter?.sources {
      conditions.append(#""s"."sourceBundleID" IN (\#(placeholders(sources.count)))"#)
      arguments += StatementArguments(sources)
    }
    if let models = filter?.deviceModels {
      // The device is the sample's own, or its provenance's (851-2674). JSON that doesn't parse
      // matches no model, rather than failing the card.
      join = #"LEFT JOIN "healthProvenances" AS "p" ON "p"."id" = "s"."provenance""#
      let device = #"coalesce("s"."device", "p"."device")"#
      conditions.append(
        #"CASE WHEN json_valid(\#(device)) THEN json_extract(\#(device), '$.model') END IN (\#(placeholders(models.count)))"#
      )
      arguments += StatementArguments(models)
    }
    let sql = """
      SELECT "s"."startDate", "s"."endDate", "s"."value", "s"."sourceBundleID"\
      \(sampleIDs ? #", "s"."id""# : "")
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
