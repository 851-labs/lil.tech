public import Foundation
import GRDB
import HealthCatalog
public import SQLiteData

/// When a type's records start: its earliest and its latest.
public struct TypeDates: Equatable, Sendable {
  public var first: Date
  public var last: Date

  public init(first: Date, last: Date) {
    self.first = first
    self.last = last
  }
}

extension HealthDatabase {
  /// When each catalog type with data has its earliest and latest records, by type ID, from
  /// wherever the type is stored. Characteristics and medications without doses have no dates,
  /// so they're left out. Activity summaries are dated at the start of their day in `calendar`.
  public static func typeDates(calendar: Calendar, _ db: Database) throws -> [String: TypeDates] {
    var dates: [String: TypeDates] = [:]
    for type in HealthCatalog.all {
      let range: (first: Int, last: Int)?
      switch type.kind {
      case .quantity, .category:
        range = try startRange(of: "healthSamples", type: type.id, db)
      case .correlation:
        range = try startRange(of: "healthCorrelations", type: type.id, db)
      case .scoredAssessment:
        range = try startRange(of: "healthScoredAssessments", type: type.id, db)
      case .workout:
        range = try startRange(of: "healthWorkouts", db)
      case .workoutRoute:
        range = try startRange(of: "healthWorkoutRoutes", db)
      case .stateOfMind:
        range = try startRange(of: "healthStateOfMinds", db)
      case .audiogram:
        range = try startRange(of: "healthAudiograms", db)
      case .electrocardiogram:
        range = try startRange(of: "healthElectrocardiograms", db)
      case .heartbeatSeries:
        range = try startRange(of: "healthHeartbeatSeries", db)
      case .visionPrescription:
        range = try startRange(of: "healthVisionPrescriptions", db)
      case .medication, .medicationDoseEvent:
        // A medication's dates are its doses'.
        range = try startRange(of: "healthMedicationDoses", db)
      case .activitySummary:
        // Keyed by their day, `yyyy-MM-dd`, which sorts by date.
        let days = try Row.fetchOne(
          db,
          sql: #"SELECT min("id") AS "first", max("id") AS "last" FROM "healthActivitySummaries""#
        )
        if let first = (days?["first"] as String?).flatMap({ gregorianDay($0, calendar: calendar) }
        ),
          let last = (days?["last"] as String?).flatMap({ gregorianDay($0, calendar: calendar) })
        {
          dates[type.id] = TypeDates(first: first, last: last)
        }
        continue
      case .characteristic, .document:
        continue
      }
      if let range {
        dates[type.id] = TypeDates(
          first: Date(unixMilliseconds: range.first), last: Date(unixMilliseconds: range.last))
      }
    }
    return dates
  }

  /// When the most recent sample of any type that has started by `now` starts, or `nil` without
  /// any.
  public static func latestSampleStart(startedBy now: Date, _ db: Database) throws -> Date? {
    // A seek of the (type, startDate) index per type: the table has no index on the start alone.
    let ids = HealthCatalog.all.filter { $0.kind == .quantity || $0.kind == .category }.map(\.id)
    var latest: Int?
    for id in ids {
      let start = try Int.fetchOne(
        db,
        sql: #"SELECT max("startDate") FROM "healthSamples" WHERE "type" = ? AND "startDate" <= ?"#,
        arguments: [id, now.unixMilliseconds])
      if let start, start > latest ?? .min { latest = start }
    }
    return latest.map(Date.init(unixMilliseconds:))
  }

  /// The earliest and latest `startDate` in `table`, of `type`'s rows if given.
  private static func startRange(
    of table: String, type: String? = nil, _ db: Database
  ) throws -> (first: Int, last: Int)? {
    // Two subqueries, so each uses the index's first or last entry rather than scanning.
    let filter = type == nil ? "" : #"WHERE "type" = :type"#
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT (SELECT min("startDate") FROM "\(table)" \(filter)) AS "first",
          (SELECT max("startDate") FROM "\(table)" \(filter)) AS "last"
        """,
      arguments: type.map { ["type": $0] } ?? [:])
    guard let first = row?["first"] as Int?, let last = row?["last"] as Int? else { return nil }
    return (first, last)
  }
}
