public import Foundation
import LilAPI
public import LilSync
import OpenAPIRuntime
public import SQLiteData

/// The Mac's local copy of the user's health data, synced with LilSync. Every screen queries
/// only this.
public enum HealthDatabase {
  /// Opens (or creates) the database at `url`, or SQLiteData's default location, and migrates
  /// it.
  public static func make(at url: URL? = nil) throws -> any DatabaseWriter {
    // A temporary database in previews and tests.
    let database = try SQLiteData.defaultDatabase(path: url?.path(percentEncoded: false))
    var migrator = DatabaseMigrator()
    LilSyncEngine.registerMigrations(in: &migrator)
    registerMigrations(in: &migrator)
    try migrator.migrate(database)
    return database
  }

  public static func registerMigrations(in migrator: inout DatabaseMigrator) {
    registerHealthTables(in: &migrator)
    migrator.registerMigration("Create health workouts") { db in
      try #sql(
        """
        CREATE TABLE "healthWorkouts" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "activityType" INTEGER NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "duration" REAL NOT NULL,
          "activities" TEXT NOT NULL,
          "events" TEXT NOT NULL,
          "statistics" TEXT NOT NULL,
          "sourceName" TEXT NOT NULL,
          "sourceBundleID" TEXT NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT,
          "metadata" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(#"CREATE INDEX "healthWorkouts_startDate" ON "healthWorkouts" ("startDate")"#)
        .execute(db)
    }
  }

  private static func registerHealthTables(in migrator: inout DatabaseMigrator) {
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
    entity("health_sample", Components.Schemas.HealthSample.self) { row in
      HealthSample(
        id: row.id, type: row._type, startDate: row.startDate, endDate: row.endDate,
        value: row.value, unit: row.unit, categoryValue: row.categoryValue,
        correlationID: row.correlationId, sourceName: row.sourceName,
        sourceBundleID: row.sourceBundleId, sourceRevision: try json(row.sourceRevision),
        device: try json(row.device), metadata: try json(row.metadata))
    },
    entity("health_correlation", Components.Schemas.HealthCorrelation.self) { row in
      HealthCorrelation(
        id: row.id, type: row._type, startDate: row.startDate, endDate: row.endDate,
        sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
        sourceRevision: try json(row.sourceRevision), device: try json(row.device),
        metadata: try json(row.metadata))
    },
    entity("health_characteristic", Components.Schemas.HealthCharacteristic.self) { row in
      HealthCharacteristic(id: row.id, value: try json(row.value) ?? "null")
    },
    entity("health_activity_summary", Components.Schemas.HealthActivitySummary.self) { row in
      HealthActivitySummary(
        id: row.id, activeEnergyBurned: row.activeEnergyBurned,
        activeEnergyBurnedGoal: row.activeEnergyBurnedGoal, appleMoveTime: row.appleMoveTime,
        appleMoveTimeGoal: row.appleMoveTimeGoal, appleExerciseTime: row.appleExerciseTime,
        appleExerciseTimeGoal: row.appleExerciseTimeGoal, appleStandHours: row.appleStandHours,
        appleStandHoursGoal: row.appleStandHoursGoal, activityMoveMode: row.activityMoveMode,
        paused: row.paused)
    },
    entity("health_statistic", Components.Schemas.HealthStatistic.self) { row in
      HealthStatistic(
        id: row.id, device: row.device, type: row._type, bucketStart: row.bucketStart,
        sum: row.sum, unit: row.unit)
    },
    entity("health_workout", Components.Schemas.HealthWorkout.self) { row in
      HealthWorkout(
        id: row.id, activityType: row.activityType, startDate: row.startDate,
        endDate: row.endDate, duration: row.duration, activities: try json(row.activities) ?? "[]",
        events: try json(row.events) ?? "[]", statistics: try json(row.statistics) ?? "{}",
        sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
        sourceRevision: try json(row.sourceRevision), device: try json(row.device),
        metadata: try json(row.metadata))
    },
    entity("health_statistics_device", Components.Schemas.HealthStatisticsDevice.self) { row in
      HealthStatisticsDevice(
        id: row.id, device: row.device, pairedWithWatch: row.pairedWithWatch,
        reportedAt: row.reportedAt)
    },
  ]

  /// An entity stored in `Record`'s table, each row made from the server's `Row`.
  private static func entity<Row: Decodable & SendableMetatype, Record: PrimaryKeyedTable>(
    _ name: String, _: Row.Type, record: @escaping @Sendable (Row) throws -> Record
  ) -> SyncEntity where Record.PrimaryKey == String, Record.QueryOutput == Record {
    .decoding(
      name, as: Row.self,
      upsert: { row, db in
        let value = try record(row)
        try Record.upsert { value }.execute(db)
      },
      delete: { id, db in try Record.find(id).delete().execute(db) },
      clear: { db in try Record.delete().execute(db) }
    )
  }

  private static let encoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  /// A JSON field as JSON text, or `nil` when it's missing or null.
  static func json(_ value: OpenAPIValueContainer?) throws -> String? {
    guard let value, value.value != nil else { return nil }
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}
