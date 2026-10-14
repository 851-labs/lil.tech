import { readdirSync, readFileSync } from "node:fs";
import { SqliteClient } from "@effect/sql-sqlite-node";
import { Effect, Layer } from "effect";
import { SqlClient } from "effect/sql";
import { CoreRepositories } from "../../src/core/CoreDatabase.ts";

const migrationsDir = new URL("../../migrations/core/", import.meta.url);

/** The migration statements, in the order Alchemy applies them on deploy. */
const migrationStatements = readdirSync(migrationsDir)
  .filter((name) => name.endsWith(".sql"))
  .sort()
  .flatMap((name) =>
    readFileSync(new URL(name, migrationsDir), "utf8")
      .replace(/--.*$/gm, "")
      .split(";")
      .map((statement) => statement.trim())
      .filter((statement) => statement.length > 0),
  );

/**
 * An in-memory SQLite database with the core migrations applied, standing in for D1 (which is
 * SQLite). Foreign keys are on, as they are in D1.
 */
export const TestCoreDatabase = Layer.effectDiscard(
  Effect.gen(function* () {
    const sql = yield* SqlClient.SqlClient;
    yield* sql`PRAGMA foreign_keys = ON`;
    for (const statement of migrationStatements) yield* sql.unsafe(statement);
  }),
).pipe(Layer.provideMerge(SqliteClient.layer({ filename: ":memory:" })));

/** The core repositories over a fresh test database. */
export const TestCore = CoreRepositories.pipe(Layer.provideMerge(TestCoreDatabase), Layer.orDie);
