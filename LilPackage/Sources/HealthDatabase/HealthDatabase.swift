public import Foundation
import LilAPI
public import LilSync
import OpenAPIRuntime
public import SQLiteData

/// The Mac's local copy of the user's health data, synced with LilSync. Every screen queries
/// only this.
public enum HealthDatabase {
  /// Opens (or creates) the database at `url` and migrates it. In memory if `url` is `nil`.
  public static func make(at url: URL? = nil) throws -> any DatabaseWriter {
    let database: any DatabaseWriter =
      if let url {
        try DatabasePool(path: url.path(percentEncoded: false))
      } else {
        try DatabaseQueue()
      }
    var migrator = DatabaseMigrator()
    LilSyncEngine.registerMigrations(in: &migrator)
    registerMigrations(in: &migrator)
    try migrator.migrate(database)
    return database
  }

  public static func registerMigrations(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("Create health tables") { db in
      try #sql(
        """
        CREATE TABLE "healthSamples" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "type" TEXT NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "value" REAL,
          "unit" TEXT,
          "categoryValue" INTEGER,
          "correlationID" TEXT,
          "sourceName" TEXT NOT NULL,
          "sourceBundleID" TEXT NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT,
          "metadata" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        #"CREATE INDEX "healthSamples_type_startDate" ON "healthSamples" ("type", "startDate")"#
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "healthCorrelations" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "type" TEXT NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "sourceName" TEXT NOT NULL,
          "sourceBundleID" TEXT NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT,
          "metadata" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "healthCharacteristics" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "value" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "healthActivitySummaries" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "activeEnergyBurned" REAL,
          "activeEnergyBurnedGoal" REAL,
          "appleMoveTime" REAL,
          "appleMoveTimeGoal" REAL,
          "appleExerciseTime" REAL,
          "appleExerciseTimeGoal" REAL,
          "appleStandHours" REAL,
          "appleStandHoursGoal" REAL,
          "activityMoveMode" TEXT,
          "paused" INTEGER
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "healthStatistics" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "device" TEXT NOT NULL,
          "type" TEXT NOT NULL,
          "bucketStart" INTEGER NOT NULL,
          "sum" REAL NOT NULL,
          "unit" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "healthStatistics_device_type_bucketStart"
        ON "healthStatistics" ("device", "type", "bucketStart")
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "healthStatisticsDevices" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "device" TEXT NOT NULL,
          "pairedWithWatch" INTEGER NOT NULL,
          "reportedAt" INTEGER NOT NULL
        ) STRICT
        """
      )
      .execute(db)
    }
  }

  /// The health entities, for ``LilSyncEngine/init(entities:partsDirectory:)``.
  public static let syncEntities: [SyncEntity] = [
    .decoding(
      "health_sample", as: Components.Schemas.HealthSample.self,
      upsert: { row, db in
        try HealthSample.upsert {
          HealthSample(
            id: row.id, type: row._type, startDate: row.startDate, endDate: row.endDate,
            value: row.value, unit: row.unit, categoryValue: row.categoryValue,
            correlationID: row.correlationId, sourceName: row.sourceName,
            sourceBundleID: row.sourceBundleId, sourceRevision: json(row.sourceRevision),
            device: json(row.device), metadata: json(row.metadata))
        }
        .execute(db)
      },
      delete: { id, db in try HealthSample.find(id).delete().execute(db) },
      clear: { db in try HealthSample.delete().execute(db) }
    ),
    .decoding(
      "health_correlation", as: Components.Schemas.HealthCorrelation.self,
      upsert: { row, db in
        try HealthCorrelation.upsert {
          HealthCorrelation(
            id: row.id, type: row._type, startDate: row.startDate, endDate: row.endDate,
            sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
            sourceRevision: json(row.sourceRevision), device: json(row.device),
            metadata: json(row.metadata))
        }
        .execute(db)
      },
      delete: { id, db in try HealthCorrelation.find(id).delete().execute(db) },
      clear: { db in try HealthCorrelation.delete().execute(db) }
    ),
    .decoding(
      "health_characteristic", as: Components.Schemas.HealthCharacteristic.self,
      upsert: { row, db in
        try HealthCharacteristic.upsert {
          HealthCharacteristic(id: row.id, value: json(row.value) ?? "null")
        }
        .execute(db)
      },
      delete: { id, db in try HealthCharacteristic.find(id).delete().execute(db) },
      clear: { db in try HealthCharacteristic.delete().execute(db) }
    ),
    .decoding(
      "health_activity_summary", as: Components.Schemas.HealthActivitySummary.self,
      upsert: { row, db in
        try HealthActivitySummary.upsert {
          HealthActivitySummary(
            id: row.id, activeEnergyBurned: row.activeEnergyBurned,
            activeEnergyBurnedGoal: row.activeEnergyBurnedGoal, appleMoveTime: row.appleMoveTime,
            appleMoveTimeGoal: row.appleMoveTimeGoal, appleExerciseTime: row.appleExerciseTime,
            appleExerciseTimeGoal: row.appleExerciseTimeGoal, appleStandHours: row.appleStandHours,
            appleStandHoursGoal: row.appleStandHoursGoal, activityMoveMode: row.activityMoveMode,
            paused: row.paused)
        }
        .execute(db)
      },
      delete: { id, db in try HealthActivitySummary.find(id).delete().execute(db) },
      clear: { db in try HealthActivitySummary.delete().execute(db) }
    ),
    .decoding(
      "health_statistic", as: Components.Schemas.HealthStatistic.self,
      upsert: { row, db in
        try HealthStatistic.upsert {
          HealthStatistic(
            id: row.id, device: row.device, type: row._type, bucketStart: row.bucketStart,
            sum: row.sum, unit: row.unit)
        }
        .execute(db)
      },
      delete: { id, db in try HealthStatistic.find(id).delete().execute(db) },
      clear: { db in try HealthStatistic.delete().execute(db) }
    ),
    .decoding(
      "health_statistics_device", as: Components.Schemas.HealthStatisticsDevice.self,
      upsert: { row, db in
        try HealthStatisticsDevice.upsert {
          HealthStatisticsDevice(
            id: row.id, device: row.device, pairedWithWatch: row.pairedWithWatch,
            reportedAt: row.reportedAt)
        }
        .execute(db)
      },
      delete: { id, db in try HealthStatisticsDevice.find(id).delete().execute(db) },
      clear: { db in try HealthStatisticsDevice.delete().execute(db) }
    ),
  ]

  private static let encoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// A JSON field as JSON text, or `nil` when it's missing or null.
  static func json(_ value: OpenAPIValueContainer?) -> String? {
    guard let value, value.value != nil else { return nil }
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
  }
}
