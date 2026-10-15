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
    // The change log (`docs/SYNC.md`). `seq` is assigned from `meta.head`, never by SQLite, so it
    // isn't reused when compaction deletes the newest changes.
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
