import { DatabaseSync } from "node:sqlite";
import type { SqlRow, SqlValue, StoreSql } from "../../src/store/StoreSql.ts";

/** A `StoreSql` over an in-memory `node:sqlite` database, standing in for Durable Object storage. */
export const makeTestStoreSql = (db = new DatabaseSync(":memory:")): StoreSql => ({
  exec: (query, ...bindings: Array<SqlValue>) =>
    db.prepare(query).all(...(bindings as Array<string | number | null>)) as Array<SqlRow>,
  script: (sql) => db.exec(sql),
  transaction: (body) => {
    db.exec("BEGIN");
    try {
      const result = body();
      db.exec("COMMIT");
      return result;
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  },
  deleteAll: async () => {
    const tables = db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
      .all() as Array<{ name: string }>;
    for (const { name } of tables) db.exec(`DROP TABLE "${name}"`);
  },
});
