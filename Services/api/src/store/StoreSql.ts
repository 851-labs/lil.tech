export type SqlValue = string | number | null | ArrayBuffer;
export type SqlRow = Record<string, SqlValue>;

/**
 * Synchronous access to a store's SQLite database. A Durable Object interleaves requests at every
 * `await`, so store writes run synchronously inside `transaction` (see `docs/SYNC.md`).
 */
export interface StoreSql {
  /** Runs one statement and returns its rows. */
  readonly exec: (query: string, ...bindings: Array<SqlValue>) => Array<SqlRow>;
  /** Runs several statements, e.g. a migration. */
  readonly script: (sql: string) => void;
  /** Runs `body` in one transaction, rolled back if it throws. `body` must not await. */
  readonly transaction: <A>(body: () => A) => A;
  /** Deletes the whole database (and anything else the store keeps). */
  readonly deleteAll: () => Promise<void>;
}

/** The parts of workerd's `DurableObjectStorage` the store uses. */
interface DurableObjectStorageLike {
  readonly sql: {
    exec(query: string, ...bindings: Array<unknown>): { toArray(): Array<SqlRow> };
  };
  transactionSync<T>(body: () => T): T;
  deleteAlarm(): Promise<void>;
  deleteAll(): Promise<void>;
}

export const fromDurableObjectStorage = (storage: DurableObjectStorageLike): StoreSql => ({
  exec: (query, ...bindings) => storage.sql.exec(query, ...bindings).toArray(),
  script: (sql) => {
    storage.sql.exec(sql);
  },
  transaction: (body) => storage.transactionSync(body),
  deleteAll: async () => {
    // `deleteAll` keeps the alarm, so it's deleted first.
    await storage.deleteAlarm();
    await storage.deleteAll();
  },
});
