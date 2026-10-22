public import Foundation
import HealthCatalog
public import SQLiteData

extension HealthDatabase {
  /// The metrics Summary shows, in order: everyday ones most iPhones record. The `summary` tool
  /// shows the same (`summaryTypes` in `Services/api`). Pins chose them until they were retired
  /// (851-2990).
  public static let summaryTypes = [
    "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierActiveEnergyBurned",
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierRestingHeartRate", "HKQuantityTypeIdentifierBodyMass",
  ]

  /// Summary's cards: each of `summaryTypes`' latest value and the week ending on it.
  public static func summaryMetrics(now: Date, calendar: Calendar, _ db: Database) throws
    -> [MetricSummary]
  {
    try summaryTypes.compactMap(HealthCatalog.type(id:)).map {
      try metricSummary(of: $0, now: now, calendar: calendar, db)
    }
  }
}
