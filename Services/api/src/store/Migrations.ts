import type { StoreSql } from "./StoreSql.ts";

export interface StoreMigration {
  readonly version: number;
  readonly name: string;
  readonly sql: string;
}

/**
 * The store's schema, in order. Append new migrations; never edit or reorder applied ones.
 *
 * A rolled-back Worker can meet a store that a newer version already migrated, so migrations must
 * be additive: older code has to keep working against a newer schema.
 */
export const storeMigrations: ReadonlyArray<StoreMigration> = [
  {
    version: 1,
    name: "meta",
    // Store-wide values, such as the sync epoch. `ANY` keeps each value's type (STRICT would
    // otherwise force one).
    sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value ANY NOT NULL) STRICT;",
  },
  {
    version: 2,
    name: "changes",
    // The change log (`docs/sync/protocol.md`). `seq` is assigned from `meta.head`, never by
    // SQLite, so it isn't reused when compaction deletes the newest changes.
    sql: `CREATE TABLE changes (
      seq INTEGER PRIMARY KEY,
      entity TEXT NOT NULL,
      id TEXT NOT NULL,
      op TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
      row TEXT,
      at INTEGER NOT NULL,
      CHECK ((op = 'upsert') = (row IS NOT NULL))
    ) STRICT;`,
  },
  {
    version: 3,
    name: "health",
    // `src/health/HealthEntities.ts`. Written out rather than generated, so that editing an entity
    // later can't change a migration that stores already ran.
    sql: `
      CREATE TABLE "health_sample" (id TEXT PRIMARY KEY, "type" TEXT NOT NULL, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "value" REAL, "unit" TEXT, "category_value" INTEGER, "correlation_id" TEXT, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_sample_type_start ON health_sample (type, start_date);
      CREATE INDEX health_sample_correlation ON health_sample (correlation_id) WHERE correlation_id IS NOT NULL;
      CREATE TABLE "health_correlation" (id TEXT PRIMARY KEY, "type" TEXT NOT NULL, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_correlation_type_start ON health_correlation (type, start_date);
      CREATE TABLE "health_characteristic" (id TEXT PRIMARY KEY, "value" TEXT NOT NULL) STRICT;
      CREATE TABLE "health_activity_summary" (id TEXT PRIMARY KEY, "active_energy_burned" REAL, "active_energy_burned_goal" REAL, "apple_move_time" REAL, "apple_move_time_goal" REAL, "apple_exercise_time" REAL, "apple_exercise_time_goal" REAL, "apple_stand_hours" REAL, "apple_stand_hours_goal" REAL, "activity_move_mode" TEXT, "paused" INTEGER) STRICT;
    `,
  },
  {
    version: 4,
    name: "health_batches",
    // Upload status for `PUT /v1/health/batches/{id}` (`src/health/HealthBatchStore.ts`).
    sql: `CREATE TABLE health_batches (
      id TEXT PRIMARY KEY,
      status TEXT NOT NULL,
      received_at INTEGER NOT NULL,
      finished_at INTEGER,
      lines INTEGER,
      applied INTEGER,
      rejected INTEGER,
      rejected_lines TEXT,
      failure TEXT,
      updated_at INTEGER NOT NULL
    ) STRICT;`,
  },
  {
    version: 5,
    name: "snapshots",
    // `src/store/Snapshots.ts`. A snapshot is published (becomes the latest) once `finished_at`
    // is set; `snapshot_job` is the one being written.
    sql: `
      CREATE TABLE snapshots (
        id TEXT PRIMARY KEY,
        seq INTEGER NOT NULL,
        epoch INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        finished_at INTEGER,
        replaced_at INTEGER,
        entity_names TEXT NOT NULL,
        entities TEXT NOT NULL
      ) STRICT;
      CREATE TABLE snapshot_job (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        snapshot_id TEXT NOT NULL REFERENCES snapshots (id),
        entity_index INTEGER NOT NULL,
        after_id TEXT,
        part INTEGER NOT NULL
      ) STRICT;
    `,
  },
  {
    version: 6,
    name: "health_statistics",
    // `HealthStatistic` and `HealthStatisticsDevice` in `src/health/HealthEntities.ts`.
    sql: `
      CREATE TABLE "health_statistic" (id TEXT PRIMARY KEY, "device" TEXT NOT NULL, "type" TEXT NOT NULL, "bucket_start" INTEGER NOT NULL, "sum" REAL NOT NULL, "unit" TEXT NOT NULL) STRICT;
      CREATE TABLE "health_statistics_device" (id TEXT PRIMARY KEY, "device" TEXT NOT NULL, "paired_with_watch" INTEGER NOT NULL, "reported_at" INTEGER NOT NULL) STRICT;
    `,
  },
  {
    version: 7,
    name: "retired_devices",
    // `src/store/RetiredDevices.ts`. The index finds a device's statistics to delete.
    sql: `
      CREATE TABLE retired_devices (
        device TEXT PRIMARY KEY,
        retired_at INTEGER NOT NULL,
        cleared_at INTEGER
      ) STRICT;
      CREATE INDEX health_statistic_by_device ON "health_statistic" ("device");
    `,
  },
  {
    version: 8,
    name: "health_workout",
    // `HealthWorkout` in `src/health/HealthEntities.ts`.
    sql: `
      CREATE TABLE "health_workout" (id TEXT PRIMARY KEY, "activity_type" INTEGER NOT NULL, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "duration" REAL NOT NULL, "activities" TEXT NOT NULL, "events" TEXT NOT NULL, "statistics" TEXT NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_workout_start ON health_workout (start_date);
    `,
  },
  {
    version: 9,
    name: "health_mental_wellbeing",
    // `HealthStateOfMind` and `HealthScoredAssessment` in `src/health/HealthEntities.ts`.
    sql: `
      CREATE TABLE "health_state_of_mind" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "kind" INTEGER NOT NULL, "valence" REAL NOT NULL, "valence_classification" INTEGER NOT NULL, "labels" TEXT NOT NULL, "associations" TEXT NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_state_of_mind_start ON health_state_of_mind (start_date);
      CREATE TABLE "health_scored_assessment" (id TEXT PRIMARY KEY, "type" TEXT NOT NULL, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "score" INTEGER NOT NULL, "risk" INTEGER NOT NULL, "answers" TEXT NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_scored_assessment_type_start ON health_scored_assessment (type, start_date);
    `,
  },
  {
    version: 10,
    name: "health_audiogram",
    // `HealthAudiogram` in `src/health/HealthEntities.ts`.
    sql: `
      CREATE TABLE "health_audiogram" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "points" TEXT NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_audiogram_start ON health_audiogram (start_date);
    `,
  },
  {
    version: 11,
    name: "health_blobs",
    // Uploaded health blobs (`src/health/HealthBlobs.ts`): which this user has, and their sizes,
    // which count towards the storage quota. `meta.health_blob_bytes` holds the total.
    sql: `
      CREATE TABLE health_blobs (
        sha256 TEXT PRIMARY KEY,
        size INTEGER NOT NULL,
        uploaded_at INTEGER NOT NULL
      ) STRICT;
    `,
  },
  {
    version: 12,
    name: "health_electrocardiogram",
    // `HealthElectrocardiogram` in `src/health/HealthEntities.ts`.
    sql: `
      CREATE TABLE "health_electrocardiogram" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "classification" INTEGER NOT NULL, "symptoms_status" INTEGER NOT NULL, "average_heart_rate" REAL, "sampling_frequency" REAL, "voltage_count" INTEGER NOT NULL, "voltages" TEXT, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_electrocardiogram_start ON health_electrocardiogram (start_date);
    `,
  },
  {
    version: 13,
    name: "health_blob_references",
    // When each blob lost its last reference, for the sweep (`src/store/BlobSweep.ts`).
    sql: `
      ALTER TABLE health_blobs ADD COLUMN unreferenced_since INTEGER;
      CREATE INDEX health_blobs_unreferenced ON health_blobs (unreferenced_since);
    `,
  },
  {
    version: 14,
    name: "health_heartbeat_series",
    // `HealthHeartbeatSeries` in `src/health/HealthEntities.ts`.
    sql: `
      CREATE TABLE "health_heartbeat_series" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "beats" TEXT NOT NULL, "gaps" TEXT NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_heartbeat_series_start ON health_heartbeat_series (start_date);
    `,
  },
  {
    version: 15,
    name: "health_workout_route",
    // `HealthWorkoutRoute` in `src/health/HealthEntities.ts`.
    sql: `
      CREATE TABLE "health_workout_route" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "workout" TEXT, "location_count" INTEGER NOT NULL, "locations" TEXT, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT) STRICT;
      CREATE INDEX health_workout_route_start ON health_workout_route (start_date);
    `,
  },
  {
    version: 16,
    name: "health_sample_by_time",
    // `HealthSample`'s key fields (`Entity.key`): stored by type, start and ID, so a backfill's
    // batches write next to each other instead of all over a UUID index (`docs/sync/protocol.md`).
    // Copying is fine for stores of synthetic data; prod's one store was emptied first (851-2651).
    // The primary key replaces `health_sample_type_start`. `tombstones` is
    // `src/store/Tombstones.ts`.
    sql: `
      CREATE TABLE "health_sample_by_time" (id TEXT NOT NULL, "type" TEXT NOT NULL, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "value" REAL, "unit" TEXT, "category_value" INTEGER, "correlation_id" TEXT, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT, PRIMARY KEY ("type", "start_date", "id")) STRICT, WITHOUT ROWID;
      INSERT INTO health_sample_by_time (id, type, start_date, end_date, value, unit, category_value, correlation_id, source_name, source_bundle_id, source_revision, device, metadata)
        SELECT id, type, start_date, end_date, value, unit, category_value, correlation_id, source_name, source_bundle_id, source_revision, device, metadata FROM health_sample;
      DROP TABLE health_sample;
      ALTER TABLE health_sample_by_time RENAME TO health_sample;
      CREATE INDEX health_sample_correlation ON health_sample (correlation_id) WHERE correlation_id IS NOT NULL;
      CREATE TABLE tombstones (
        entity TEXT NOT NULL,
        id TEXT NOT NULL,
        at INTEGER NOT NULL,
        PRIMARY KEY (entity, id)
      ) STRICT, WITHOUT ROWID;
      CREATE INDEX tombstones_at ON tombstones (at);
    `,
  },
  {
    version: 17,
    name: "changes_key",
    // `key` holds an upsert's record's key fields' values as a JSON array (`Entity.key`), or NULL
    // without key fields, so `readChanges` can read its row from its table. Since 851-2676,
    // changes don't carry a copy of their row (`logsRowCopies`): their `row` is '' (the CHECK on
    // `changes` still wants one). Code from before 851-2673 can't read those
    // (`docs/sync/protocol.md`).
    sql: "ALTER TABLE changes ADD COLUMN key TEXT;",
  },
  {
    version: 18,
    name: "health_batches_queued",
    // The batches waiting their turn, in the order they were received (`healthBatchesAhead`).
    sql: "CREATE INDEX health_batches_queued ON health_batches (received_at, id) WHERE status = 'queued';",
  },
  {
    version: 19,
    name: "health_provenance",
    // `HealthProvenance`, and the `provenance` field of the entities with a source and device
    // (`src/health/HealthEntities.ts`, 851-2674).
    sql: `
      CREATE TABLE "health_provenance" (id TEXT PRIMARY KEY, "source_revision" TEXT, "device" TEXT) STRICT;
      ALTER TABLE "health_sample" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_correlation" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_workout" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_state_of_mind" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_scored_assessment" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_audiogram" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_electrocardiogram" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_heartbeat_series" ADD COLUMN "provenance" TEXT;
      ALTER TABLE "health_workout_route" ADD COLUMN "provenance" TEXT;
    `,
  },
  {
    version: 20,
    name: "health_pin",
    // `HealthPin` (`src/health/HealthPins.ts`), and the mutation IDs `POST /v1/sync/mutations`
    // answers again for 7 days (`pushMutations`, 851-2641).
    sql: `
      CREATE TABLE "health_pin" (id TEXT PRIMARY KEY, "position" REAL NOT NULL) STRICT;
      CREATE TABLE pushed_mutations (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, at INTEGER NOT NULL) STRICT;
      CREATE INDEX pushed_mutations_at ON pushed_mutations (at);
    `,
  },
  {
    version: 21,
    name: "health_vision_prescription",
    // `HealthVisionPrescription` in `src/health/HealthEntities.ts` (851-2572).
    sql: `
      CREATE TABLE "health_vision_prescription" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "prescription_type" INTEGER NOT NULL, "expiration_date" INTEGER, "brand" TEXT, "right_eye" TEXT, "left_eye" TEXT, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT, "provenance" TEXT) STRICT;
      CREATE INDEX health_vision_prescription_start ON health_vision_prescription (start_date);
    `,
  },
  {
    version: 22,
    name: "health_medication",
    // `HealthMedication` and `HealthMedicationDose` in `src/health/HealthEntities.ts` (851-2571).
    sql: `
      CREATE TABLE "health_medication" (id TEXT PRIMARY KEY, "name" TEXT NOT NULL, "nickname" TEXT, "general_form" TEXT NOT NULL, "is_archived" INTEGER NOT NULL, "has_schedule" INTEGER NOT NULL, "codings" TEXT NOT NULL) STRICT;
      CREATE TABLE "health_medication_dose" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "medication" TEXT NOT NULL, "log_status" INTEGER NOT NULL, "schedule_type" INTEGER NOT NULL, "scheduled_date" INTEGER, "scheduled_dose_quantity" REAL, "dose_quantity" REAL, "unit" TEXT NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT, "provenance" TEXT) STRICT;
      CREATE INDEX health_medication_dose_start ON health_medication_dose (start_date);
      CREATE INDEX health_medication_dose_medication ON health_medication_dose (medication, start_date);
    `,
  },
  {
    version: 23,
    name: "health_document",
    // `HealthDocument` in `src/health/HealthEntities.ts` (851-2836).
    sql: `
      CREATE TABLE "health_document" (id TEXT PRIMARY KEY, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "title" TEXT NOT NULL, "patient_name" TEXT NOT NULL, "author_name" TEXT NOT NULL, "custodian_name" TEXT NOT NULL, "xml" TEXT NOT NULL, "source_name" TEXT NOT NULL, "source_bundle_id" TEXT NOT NULL, "source_revision" TEXT, "device" TEXT, "metadata" TEXT, "provenance" TEXT) STRICT;
      CREATE INDEX health_document_start ON health_document (start_date);
    `,
  },
  {
    version: 24,
    name: "agent_access_log",
    // Agents' tool calls at the MCP servers (851-2851, `src/store/AgentAccessLog.ts`). Not an
    // entity: it isn't synced. Rows are added in time order, so the rowid orders them.
    sql: `CREATE TABLE agent_access_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      at INTEGER NOT NULL,
      grant_id TEXT NOT NULL,
      client_name TEXT NOT NULL,
      tool TEXT NOT NULL,
      types TEXT,
      range TEXT,
      date TEXT,
      outcome TEXT NOT NULL,
      rows INTEGER NOT NULL
    ) STRICT;`,
  },
  {
    version: 25,
    name: "mcp_sessions",
    // Agents' MCP sessions, so they outlive the store's object (851-2947,
    // `src/store/McpSessions.ts`). Not an entity: it isn't synced.
    sql: `CREATE TABLE mcp_sessions (
      id TEXT PRIMARY KEY,
      server TEXT NOT NULL,
      initialize TEXT NOT NULL,
      used_at INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX mcp_sessions_used_at ON mcp_sessions (used_at);`,
  },
  {
    version: 26,
    name: "changes_entity_seq",
    // The change feed's `entities` filter (851-3221, `readChanges`): one entity's changes in log
    // order, without reading the others' (e.g. a phone pulling cards past millions of samples).
    sql: "CREATE INDEX changes_entity_seq ON changes (entity, seq);",
  },
  {
    version: 27,
    name: "health_card",
    // `HealthCard` (`src/health/cards/HealthCards.ts`): Summary's cards (851-3202).
    sql: `CREATE TABLE "health_card" (
      id TEXT PRIMARY KEY,
      "spec" TEXT NOT NULL,
      "position" TEXT NOT NULL,
      "created_at" INTEGER NOT NULL,
      "updated_at" INTEGER NOT NULL,
      "seed" TEXT
    ) STRICT;`,
  },
];

/** The store's schema version: its newest applied migration. */
export const schemaVersion = (sql: StoreSql): number =>
  Number(sql.exec("SELECT max(version) AS version FROM store_migrations")[0]?.["version"] ?? 0);

/**
 * Applies the migrations the store doesn't have yet, each in its own transaction with its
 * `store_migrations` row, and returns the store's schema version. Throws if `migrations` isn't
 * numbered 1, 2, 3…, if the store's history doesn't match it, or if a migration fails (the store
 * keeps the versions before it).
 */
export const migrate = (sql: StoreSql, migrations = storeMigrations): number => {
  for (const [index, migration] of migrations.entries()) {
    if (migration.version !== index + 1) {
      throw new Error(`Store migration ${index + 1} is numbered ${migration.version}`);
    }
  }
  sql.script(`CREATE TABLE IF NOT EXISTS store_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at INTEGER NOT NULL
  ) STRICT;`);
  const applied = sql.exec("SELECT version, name FROM store_migrations ORDER BY version");
  for (const [index, row] of applied.entries()) {
    // Newer code may have applied migrations this code doesn't know about yet.
    const migration = migrations[index];
    if (
      row["version"] !== index + 1 ||
      (migration !== undefined && row["name"] !== migration.name)
    ) {
      throw new Error(`Store migration history conflict: applied ${JSON.stringify(row)}`);
    }
  }
  for (const migration of migrations.slice(applied.length)) {
    sql.transaction(() => {
      sql.script(migration.sql);
      sql.exec(
        "INSERT INTO store_migrations (version, name, applied_at) VALUES (?, ?, ?)",
        migration.version,
        migration.name,
        Date.now(),
      );
    });
  }
  return schemaVersion(sql);
};
