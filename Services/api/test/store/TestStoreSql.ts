import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import type { SqlRow, SqlValue, StoreSql } from "../../src/store/StoreSql.ts";

// workerd binds and returns blobs as ArrayBuffer; node:sqlite as Uint8Array.
const toNode = (value: SqlValue): SQLInputValue =>
  value instanceof ArrayBuffer ? new Uint8Array(value) : value;
const fromNode = (value: unknown): SqlValue =>
  value instanceof Uint8Array ? value.slice().buffer : (value as SqlValue);

/** A test `StoreSql`, whose reported size a test can set to fill it up. */
export interface TestStoreSql extends StoreSql {
  /** Makes `databaseSize` report `bytes`, or the real size again with `null`. */
  readonly setDatabaseSize: (bytes: number | null) => void;
}

/**
 * A `StoreSql` over an in-memory `node:sqlite` database, standing in for Durable Object storage.
 * Transactions nest with savepoints, as `transactionSync` does, and `deleteAll` starts a new
 * database, as workerd does.
 */
export const makeTestStoreSql = (): TestStoreSql => {
  let db = new DatabaseSync(":memory:");
  let depth = 0;
  let alarm: number | null = null;
  let size: number | null = null;
  return {
    exec: (query, ...bindings) =>
      (db.prepare(query).all(...bindings.map(toNode)) as Array<Record<string, unknown>>).map(
        (row) =>
          Object.fromEntries(
            Object.entries(row).map(([key, value]) => [key, fromNode(value)]),
          ) as SqlRow,
      ),
    rows: (query, ...bindings) => {
      const statement = db.prepare(query);
      statement.setReturnArrays(true);
      return (statement.all(...bindings.map(toNode)) as unknown as Array<Array<unknown>>).map(
        (row) => row.map(fromNode),
      );
    },
    script: (sql) => db.exec(sql),
    transaction: (body) => {
      const savepoint = `transaction_${depth++}`;
      db.exec(`SAVEPOINT ${savepoint}`);
      try {
        const result = body();
        db.exec(`RELEASE ${savepoint}`);
        return result;
      } catch (error) {
        db.exec(`ROLLBACK TO ${savepoint}`);
        db.exec(`RELEASE ${savepoint}`);
        throw error;
      } finally {
        depth--;
      }
    },
    deleteAll: async () => {
      db.close();
      db = new DatabaseSync(":memory:");
      alarm = null;
    },
    getAlarm: async () => alarm,
    setAlarm: async (at) => {
      alarm = at;
    },
    databaseSize: () => {
      if (size !== null) return size;
      const [row] = db
        // As workerd counts it: used pages only.
        .prepare(
          `SELECT (page_count - freelist_count) * page_size AS size
          FROM pragma_page_count, pragma_freelist_count, pragma_page_size`,
        )
        .all() as Array<{ size: number }>;
      return row?.size ?? 0;
    },
    setDatabaseSize: (bytes) => {
      size = bytes;
    },
  };
};
