import { existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { SqliteClient } from "@effect/sql-sqlite-node";
import { Effect, Layer } from "effect";
import { SqlClient } from "effect/sql";
import { CoreRepositories } from "../../src/core/CoreDatabase.ts";

const migrationsDir = new URL("../../migrations/core/", import.meta.url);

/**
 * Migrations as Alchemy finds them on deploy: drizzle-kit's folders (`<timestamp>_<name>`) that
 * hold a `migration.sql`, by name.
 */
const migrations = readdirSync(migrationsDir, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && /^\d{14}_/.test(entry.name))
  .map((entry) => entry.name)
  .filter((name) => existsSync(new URL(`${name}/migration.sql`, migrationsDir)))
  .sort((a, b) => a.localeCompare(b))
  .map((name) => readFileSync(new URL(`${name}/migration.sql`, migrationsDir), "utf8"));

/**
 * A fresh SQLite database file with the core migrations applied, standing in for D1 (which is
 * SQLite). Like Alchemy, each migration is split on `--> statement-breakpoint` and each piece runs
 * as one statement: as on D1, anything after a piece's first statement is ignored, so a missing
 * breakpoint shows up here too. Foreign keys are on, as they are in D1.
 */
export const TestCoreDatabase = Layer.unwrap(
  Effect.sync(() => {
    const filename = join(mkdtempSync(join(tmpdir(), "lil-core-")), "core.sqlite");
    const db = new DatabaseSync(filename);
    for (const migration of migrations) {
      for (const statement of migration.split("--> statement-breakpoint")) {
        if (statement.trim() !== "") db.prepare(statement).run();
      }
    }
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
