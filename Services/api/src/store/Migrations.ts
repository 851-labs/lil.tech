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
    // Store-wide values, such as the sync epoch.
    sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;",
  },
];

/**
 * Applies the migrations the store doesn't have yet, each in its own transaction with its
 * `store_migrations` row, and returns the store's schema version. Throws if the store's history
 * doesn't match `migrations`, or if a migration fails (the store keeps the versions before it).
 */
export const migrate = (sql: StoreSql, migrations = storeMigrations): number => {
  sql.script(`CREATE TABLE IF NOT EXISTS store_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at INTEGER NOT NULL
  ) STRICT;`);
  const applied = sql.exec("SELECT version, name FROM store_migrations ORDER BY version");
  for (const [index, row] of applied.entries()) {
    const migration = migrations[index];
    // Newer code may have applied migrations this code doesn't know about yet.
    if (migration === undefined) break;
    if (row["version"] !== migration.version || row["name"] !== migration.name) {
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
  return Math.max(applied.length, migrations.length);
};
