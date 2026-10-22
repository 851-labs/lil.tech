public import Foundation
import GRDB
public import LilAPI
public import LilSync
import OpenAPIRuntime
public import SQLiteData

/// The Mac's local copy of the user's health data, synced with LilSync. Every screen queries
/// only this.
public enum HealthDatabase {
  /// The Mac app's own folder in Application Support for this build's server, where it keeps
  /// `Health.sqlite` and the agent access setting and log (`AgentAccessStore`). The app isn't
  /// sandboxed, so the folder is shared with every app otherwise. Spelled out rather than taken
  /// from the bundle ID, so the `lil-health` command, which has none, finds the same folder: it
  /// picks the server the same way (`LIL_API_URL` in its environment, in a Debug build).
  public static var macDirectory: URL {
    macDirectory(for: .current())
  }

  /// The Mac app's folder for `environment`'s data (851-2977): `tech.lil.health` in
  /// `applicationSupport`, as always, for a build that only uses prod (Release), and a folder per
  /// server inside it for builds that can use another (Debug), e.g.
  /// `tech.lil.health/Servers/api.staging.lil.tech`, so a Debug build signed out of its server
  /// can't delete the Release app's data, or another server's.
  public static func macDirectory(
    for environment: APIEnvironment,
    allowsOverride: Bool = APIEnvironment.allowsOverride,
    applicationSupport: URL = .applicationSupportDirectory
  ) -> URL {
    environment.localDirectory(
      in: applicationSupport.appending(path: "tech.lil.health", directoryHint: .isDirectory),
      allowsOverride: allowsOverride)
  }

  /// Opens (or creates) the database at `url`, or SQLiteData's default location, and migrates
  /// it.
  public static func make(at url: URL? = nil) throws -> any DatabaseWriter {
    // A temporary database in tests and snapshot catalogs.
    let database = try SQLiteData.defaultDatabase(path: url?.path(percentEncoded: false))
    try migrator.migrate(database)
    return database
  }

  /// Every migration of the database, sync's and the health tables'.
  public static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    LilSyncEngine.registerMigrations(in: &migrator)
    registerMigrations(in: &migrator)
    return migrator
  }

  /// Opens the database at `url` to read it, alongside the app, as `lil-health` does (851-2843).
  /// It's read-only: the app's database is in WAL mode, so reads see its last commit while it
  /// writes. It never migrates, so it refuses a database migrated by a newer release, whose
  /// tables this one may misread, and one the app hasn't migrated yet.
  public static func openForReading(at url: URL) throws -> any DatabaseReader {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      throw ReadError.missing
    }
    var configuration = Configuration()
    configuration.readonly = true
    // The app may be checkpointing or writing a large sync batch.
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { db in
      db.add(collation: .canonical)
    }
    let database = try DatabasePool(
      path: url.path(percentEncoded: false), configuration: configuration)
    try database.read { db in
      let migrator = Self.migrator
      if try migrator.hasBeenSuperseded(db) { throw ReadError.newerSchema }
      if try !migrator.hasCompletedMigrations(db) { throw ReadError.olderSchema }
    }
    return database
  }

  /// Why `openForReading(at:)` couldn't open the database.
  public enum ReadError: LocalizedError, Equatable {
    /// There's no database: lil health hasn't run on this Mac.
    case missing
    /// A newer release of lil health migrated it.
    case newerSchema
    /// lil health hasn't migrated it since an update.
    case olderSchema

    public var errorDescription: String? {
      switch self {
      case .missing:
        "There's no lil health data on this Mac yet. Open lil health, sign in, and let it sync."
      case .newerSchema:
        """
        lil health's data on this Mac is from a newer version of lil health than this command. \
        Use the lil-health inside the latest lil health.app.
        """
      case .olderSchema:
        "lil health's data on this Mac needs updating. Open lil health once, then try again."
      }
    }
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
    migrator.registerMigration("Create State of Mind and scored assessments") { db in
      try #sql(
        """
        CREATE TABLE "healthStateOfMinds" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "kind" INTEGER NOT NULL,
          "valence" REAL NOT NULL,
          "valenceClassification" INTEGER NOT NULL,
          "labels" TEXT NOT NULL,
          "associations" TEXT NOT NULL,
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
        CREATE TABLE "healthScoredAssessments" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "type" TEXT NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "score" INTEGER NOT NULL,
          "risk" INTEGER NOT NULL,
          "answers" TEXT NOT NULL,
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
        #"CREATE INDEX "healthStateOfMinds_startDate" ON "healthStateOfMinds" ("startDate")"#
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "healthScoredAssessments_type_startDate"
        ON "healthScoredAssessments" ("type", "startDate")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create audiograms") { db in
      try #sql(
        """
        CREATE TABLE "healthAudiograms" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "points" TEXT NOT NULL,
          "sourceName" TEXT NOT NULL,
          "sourceBundleID" TEXT NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT,
          "metadata" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(#"CREATE INDEX "healthAudiograms_startDate" ON "healthAudiograms" ("startDate")"#)
        .execute(db)
    }
    migrator.registerMigration("Create ECGs") { db in
      try #sql(
        """
        CREATE TABLE "healthElectrocardiograms" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "classification" INTEGER NOT NULL,
          "symptomsStatus" INTEGER NOT NULL,
          "averageHeartRate" REAL,
          "samplingFrequency" REAL,
          "voltageCount" INTEGER NOT NULL,
          "voltages" TEXT,
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
        #"CREATE INDEX "healthElectrocardiograms_startDate" ON "healthElectrocardiograms" ("startDate")"#
      )
      .execute(db)
    }
    migrator.registerMigration("Create heartbeat series") { db in
      try #sql(
        """
        CREATE TABLE "healthHeartbeatSeries" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "beats" TEXT NOT NULL,
          "gaps" TEXT NOT NULL,
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
        #"CREATE INDEX "healthHeartbeatSeries_startDate" ON "healthHeartbeatSeries" ("startDate")"#
      )
      .execute(db)
    }
    migrator.registerMigration("Create workout routes") { db in
      try #sql(
        """
        CREATE TABLE "healthWorkoutRoutes" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "workout" TEXT,
          "locationCount" INTEGER NOT NULL,
          "locations" TEXT,
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
        #"CREATE INDEX "healthWorkoutRoutes_startDate" ON "healthWorkoutRoutes" ("startDate")"#
      )
      .execute(db)
    }
    migrator.registerMigration("Add health provenance") { db in
      try #sql(
        """
        CREATE TABLE "healthProvenances" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT
        ) STRICT
        """
      )
      .execute(db)
      for table in [
        "healthSamples", "healthCorrelations", "healthWorkouts", "healthStateOfMinds",
        "healthScoredAssessments", "healthAudiograms", "healthElectrocardiograms",
        "healthHeartbeatSeries", "healthWorkoutRoutes",
      ] {
        try db.execute(sql: #"ALTER TABLE "\#(table)" ADD COLUMN "provenance" TEXT"#)
      }
    }
    migrator.registerMigration("Create health pins") { db in
      try #sql(
        """
        CREATE TABLE "healthPins" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "position" REAL NOT NULL
        ) STRICT
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create vision prescriptions") { db in
      try #sql(
        """
        CREATE TABLE "healthVisionPrescriptions" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "prescriptionType" INTEGER NOT NULL,
          "expirationDate" INTEGER,
          "brand" TEXT,
          "rightEye" TEXT,
          "leftEye" TEXT,
          "sourceName" TEXT NOT NULL,
          "sourceBundleID" TEXT NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT,
          "metadata" TEXT,
          "provenance" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        #"CREATE INDEX "healthVisionPrescriptions_startDate" ON "healthVisionPrescriptions" ("startDate")"#
      )
      .execute(db)
    }
    migrator.registerMigration("Create medications and doses") { db in
      try #sql(
        """
        CREATE TABLE "healthMedications" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "name" TEXT NOT NULL,
          "nickname" TEXT,
          "generalForm" TEXT NOT NULL,
          "isArchived" INTEGER NOT NULL,
          "hasSchedule" INTEGER NOT NULL,
          "codings" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "healthMedicationDoses" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "medication" TEXT NOT NULL,
          "logStatus" INTEGER NOT NULL,
          "scheduleType" INTEGER NOT NULL,
          "scheduledDate" INTEGER,
          "scheduledDoseQuantity" REAL,
          "doseQuantity" REAL,
          "unit" TEXT NOT NULL,
          "sourceName" TEXT NOT NULL,
          "sourceBundleID" TEXT NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT,
          "metadata" TEXT,
          "provenance" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        #"CREATE INDEX "healthMedicationDoses_startDate" ON "healthMedicationDoses" ("startDate")"#
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "healthMedicationDoses_medication" \
        ON "healthMedicationDoses" ("medication", "startDate")
        """
      )
      .execute(db)
    }
    migrator.registerMigration("Create documents") { db in
      try #sql(
        """
        CREATE TABLE "healthDocuments" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "startDate" INTEGER NOT NULL,
          "endDate" INTEGER NOT NULL,
          "title" TEXT NOT NULL,
          "patientName" TEXT NOT NULL,
          "authorName" TEXT NOT NULL,
          "custodianName" TEXT NOT NULL,
          "xml" TEXT NOT NULL,
          "sourceName" TEXT NOT NULL,
          "sourceBundleID" TEXT NOT NULL,
          "sourceRevision" TEXT,
          "device" TEXT,
          "metadata" TEXT,
          "provenance" TEXT
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        #"CREATE INDEX "healthDocuments_startDate" ON "healthDocuments" ("startDate")"#
      )
      .execute(db)
    }
    // Blood pressure readings: correlations by type and time, and their samples by
    // correlation (851-2832).
    migrator.registerMigration("Index samples by correlation") { db in
      try #sql(
        #"CREATE INDEX "healthSamples_correlationID" ON "healthSamples" ("correlationID")"#
      )
      .execute(db)
      try #sql(
        """
        CREATE INDEX "healthCorrelations_type_startDate"
        ON "healthCorrelations" ("type", "startDate")
        """
      )
      .execute(db)
    }
    // Summary's pins are retired (851-2990): `health_pin` no longer syncs to the Mac, so rows
    // here would never change again, nor go when the account signs out. The table stays for an
    // older release, if one is reinstalled. Sync's own tables are migrated first, so this also
    // drops pin writes still waiting to be pushed (only pins were ever pushed, a batch at a
    // time), which nothing could apply now, and takes `health_pin` out of the entities the
    // local data records, so a reinstalled older release bootstraps and gets the pins back.
    migrator.registerMigration("Retire health pins") { db in
      try #sql(#"DELETE FROM "healthPins""#).execute(db)
      try #sql(
        """
        DELETE FROM "lilPendingMutations"
        WHERE EXISTS (
          SELECT 1 FROM json_each("lilPendingMutations"."mutations")
          WHERE json_extract(json_each.value, '$.entity') = 'health_pin'
        )
        """
      )
      .execute(db)
      try #sql(
        """
        UPDATE "lilSyncState"
        SET "entities" = trim(replace(',' || "entities" || ',', ',health_pin,', ','), ',')
        WHERE "entities" IS NOT NULL
        """
      )
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

  /// The sync schema number to pass to `SyncClient.live(entities:syncSchema:)`. Bump it in a
  /// release that starts storing a new field of an entity it already has, so Macs synced by an
  /// earlier release bootstrap again and get it (`docs/sync/protocol.md`). New entities need none.
  public static let syncSchema = 2

  /// The health entities, for ``LilSyncEngine/init(entities:syncSchema:partsDirectory:)``.
  public static let syncEntities: [SyncEntity] = [
    entity("health_provenance", Components.Schemas.HealthProvenance.self) { row in
      HealthProvenance(
        id: row.id, sourceRevision: try json(row.sourceRevision), device: try json(row.device))
    },
    entity("health_sample", Components.Schemas.HealthSample.self) { row in
      HealthSample(
        id: row.id, type: row._type, startDate: row.startDate, endDate: row.endDate,
        value: row.value, unit: row.unit, categoryValue: row.categoryValue,
        correlationID: row.correlationId, sourceName: row.sourceName,
        sourceBundleID: row.sourceBundleId, sourceRevision: try json(row.sourceRevision),
        device: try json(row.device), metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_correlation", Components.Schemas.HealthCorrelation.self) { row in
      HealthCorrelation(
        id: row.id, type: row._type, startDate: row.startDate, endDate: row.endDate,
        sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
        sourceRevision: try json(row.sourceRevision), device: try json(row.device),
        metadata: try json(row.metadata), provenance: row.provenance)
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
        metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_state_of_mind", Components.Schemas.HealthStateOfMind.self) { row in
      HealthStateOfMind(
        id: row.id, startDate: row.startDate, endDate: row.endDate, kind: row.kind,
        valence: row.valence, valenceClassification: row.valenceClassification,
        labels: try json(row.labels) ?? "[]", associations: try json(row.associations) ?? "[]",
        sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
        sourceRevision: try json(row.sourceRevision), device: try json(row.device),
        metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_scored_assessment", Components.Schemas.HealthScoredAssessment.self) { row in
      HealthScoredAssessment(
        id: row.id, type: row._type, startDate: row.startDate, endDate: row.endDate,
        score: row.score, risk: row.risk, answers: try json(row.answers) ?? "[]",
        sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
        sourceRevision: try json(row.sourceRevision), device: try json(row.device),
        metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_audiogram", Components.Schemas.HealthAudiogram.self) { row in
      HealthAudiogram(
        id: row.id, startDate: row.startDate, endDate: row.endDate,
        points: try json(row.points) ?? "[]", sourceName: row.sourceName,
        sourceBundleID: row.sourceBundleId, sourceRevision: try json(row.sourceRevision),
        device: try json(row.device), metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_electrocardiogram", Components.Schemas.HealthElectrocardiogram.self) { row in
      HealthElectrocardiogram(
        id: row.id, startDate: row.startDate, endDate: row.endDate,
        classification: row.classification, symptomsStatus: row.symptomsStatus,
        averageHeartRate: row.averageHeartRate, samplingFrequency: row.samplingFrequency,
        voltageCount: row.voltageCount, voltages: row.voltages, sourceName: row.sourceName,
        sourceBundleID: row.sourceBundleId, sourceRevision: try json(row.sourceRevision),
        device: try json(row.device), metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_workout_route", Components.Schemas.HealthWorkoutRoute.self) { row in
      HealthWorkoutRoute(
        id: row.id, startDate: row.startDate, endDate: row.endDate, workout: row.workout,
        locationCount: row.locationCount, locations: row.locations, sourceName: row.sourceName,
        sourceBundleID: row.sourceBundleId, sourceRevision: try json(row.sourceRevision),
        device: try json(row.device), metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_heartbeat_series", Components.Schemas.HealthHeartbeatSeries.self) { row in
      HealthHeartbeatSeries(
        id: row.id, startDate: row.startDate, endDate: row.endDate,
        beats: try json(row.beats) ?? "[]", gaps: try json(row.gaps) ?? "[]",
        sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
        sourceRevision: try json(row.sourceRevision), device: try json(row.device),
        metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_vision_prescription", Components.Schemas.HealthVisionPrescription.self) {
      row in
      HealthVisionPrescription(
        id: row.id, startDate: row.startDate, endDate: row.endDate,
        prescriptionType: row.prescriptionType, expirationDate: row.expirationDate,
        brand: row.brand, rightEye: try json(row.rightEye), leftEye: try json(row.leftEye),
        sourceName: row.sourceName, sourceBundleID: row.sourceBundleId,
        sourceRevision: try json(row.sourceRevision), device: try json(row.device),
        metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_medication", Components.Schemas.HealthMedication.self) { row in
      HealthMedication(
        id: row.id, name: row.name, nickname: row.nickname, generalForm: row.generalForm,
        isArchived: row.isArchived, hasSchedule: row.hasSchedule,
        codings: try json(row.codings) ?? "[]")
    },
    entity("health_medication_dose", Components.Schemas.HealthMedicationDose.self) { row in
      HealthMedicationDose(
        id: row.id, startDate: row.startDate, endDate: row.endDate, medication: row.medication,
        logStatus: row.logStatus, scheduleType: row.scheduleType,
        scheduledDate: row.scheduledDate, scheduledDoseQuantity: row.scheduledDoseQuantity,
        doseQuantity: row.doseQuantity, unit: row.unit, sourceName: row.sourceName,
        sourceBundleID: row.sourceBundleId, sourceRevision: try json(row.sourceRevision),
        device: try json(row.device), metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_document", Components.Schemas.HealthDocument.self) { row in
      HealthDocument(
        id: row.id, startDate: row.startDate, endDate: row.endDate, title: row.title,
        patientName: row.patientName, authorName: row.authorName,
        custodianName: row.custodianName, xml: row.xml, sourceName: row.sourceName,
        sourceBundleID: row.sourceBundleId, sourceRevision: try json(row.sourceRevision),
        device: try json(row.device), metadata: try json(row.metadata), provenance: row.provenance)
    },
    entity("health_statistics_device", Components.Schemas.HealthStatisticsDevice.self) { row in
      HealthStatisticsDevice(
        id: row.id, device: row.device, pairedWithWatch: row.pairedWithWatch,
        reportedAt: row.reportedAt)
    },
  ]

  /// An entity stored in `Record`'s table, each row made from the server's `Row`. Rows are
  /// upserted through one cached statement per table (``PreparedUpsert``): building each row's
  /// query cost about 20 times as much as the insert itself (68 µs against 3 µs a sample,
  /// 851-2649). Snapshots load through a staging table, which keeps loading as fast for a million
  /// records as for 200,000 (851-2859).
  private static func entity<Row: Decodable & SendableMetatype, Record: PrimaryKeyedTable>(
    _ name: String, _: Row.Type, record: @escaping @Sendable (Row) throws -> Record
  ) -> SyncEntity where Record.PrimaryKey == String, Record.QueryOutput == Record {
    let upsert = PreparedUpsert<Record>()
    return .decoding(
      name, as: Row.self, table: Record.tableName,
      insert: { row, staging, db in try upsert.insert(try record(row), into: staging, db) },
      upsert: { row, db in try upsert.execute(try record(row), db) },
      delete: delete(Record.self),
      clear: clear(Record.self)
    )
  }

  private static func delete<Record: PrimaryKeyedTable>(
    _: Record.Type
  ) -> @Sendable (String, Database) throws -> Void where Record.PrimaryKey == String {
    { id, db in try Record.find(id).delete().execute(db) }
  }

  private static func clear<Record: PrimaryKeyedTable>(
    _: Record.Type
  ) -> @Sendable (Database) throws -> Void {
    { db in try Record.delete().execute(db) }
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
