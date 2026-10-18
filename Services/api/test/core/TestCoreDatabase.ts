import { mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { SqliteClient } from "@effect/sql-sqlite-node";
import { Effect, Layer } from "effect";
import { SqlClient } from "effect/sql";
import { CoreRepositories } from "../../src/core/CoreDatabase.ts";

const migrationsDir = new URL("../../migrations/core/", import.meta.url);

/**
 * Migrations in the order Alchemy applies them on deploy: drizzle-kit's folders
 * (`<timestamp>_<name>/migration.sql`), by name.
 */
const migrations = readdirSync(migrationsDir, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort()
  .map((name) => readFileSync(new URL(`${name}/migration.sql`, migrationsDir), "utf8"));

/**
 * A fresh SQLite database file with the core migrations applied, standing in for D1 (which is
 * SQLite). Each migration file runs whole, as Alchemy sends it to D1. Foreign keys are on, as they
 * are in D1.
 */
export const TestCoreDatabase = Layer.unwrap(
  Effect.sync(() => {
    const filename = join(mkdtempSync(join(tmpdir(), "lil-core-")), "core.sqlite");
    const db = new DatabaseSync(filename);
    for (const migration of migrations) db.exec(migration);
    db.close();
    return Layer.effectDiscard(
      Effect.gen(function* () {
        const sql = yield* SqlClient.SqlClient;
        yield* sql`PRAGMA foreign_keys = ON`;
      }),
    ).pipe(Layer.provideMerge(SqliteClient.layer({ filename })));
  }),
);

/** The core repositories over a fresh test database. */
export const TestCore = CoreRepositories.pipe(Layer.provideMerge(TestCoreDatabase), Layer.orDie);
