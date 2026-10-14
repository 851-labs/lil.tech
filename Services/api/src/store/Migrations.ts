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
      failure TEXT
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
