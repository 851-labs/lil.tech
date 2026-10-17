import type { Entity } from "./Entities.ts";
import type { SqlValue, StoreSql } from "./StoreSql.ts";

// Records of an entity with key fields (`Entity.key`) are stored in their key's order, so one
// can't be found by its ID alone. A delete leaves a tombstone instead (`applyMutations`), and the
// change log has the delete at once. The store's alarm removes the rows later, in passes over
// each such table a chunk at a time. Until then, reads skip tombstoned records (`docs/SYNC.md`).

export const tombstonePolicy = {
  /** How long the oldest tombstone waits before a pass starts, so a pass covers many. */
  delay: 60 * 60 * 1000,
  /** Rows looked at per alarm, in one transaction. */
  chunkRows: 50_000,
  /** The time between a pass's alarms, so it doesn't monopolize the store. */
  stepInterval: 2_000,
};

export type TombstonePolicy = typeof tombstonePolicy;

/** A pass in progress: the entity it's on, the last key it looked at, and when it started. */
interface Pass {
  readonly entity: number;
  readonly after: ReadonlyArray<SqlValue> | null;
  readonly startedAt: number;
  readonly steppedAt: number;
}

const readPass = (sql: StoreSql): Pass | null => {
  const value = sql.exec("SELECT value FROM meta WHERE key = 'tombstone_pass'")[0]?.["value"];
  return typeof value === "string" ? (JSON.parse(value) as Pass) : null;
};

const savePass = (sql: StoreSql, pass: Pass | null) => {
  if (pass === null) {
    sql.exec("DELETE FROM meta WHERE key = 'tombstone_pass'");
    return;
  }
  sql.exec(
    `INSERT INTO meta (key, value) VALUES ('tombstone_pass', ?)
      ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
    JSON.stringify(pass),
  );
};

/** `"a", "b"`: an entity's primary key columns, for SQL. */
const keyList = (entity: Entity) => entity.keyColumns.map((column) => `"${column}"`).join(", ");

/**
 * Its rows after `after` in key order, as a `WHERE` clause and its bindings (none from the start).
 */
export const afterKey = (entity: Entity, after: ReadonlyArray<SqlValue> | null) =>
  after === null
    ? { where: "TRUE", bindings: [] as ReadonlyArray<SqlValue> }
    : {
        where: `(${keyList(entity)}) > (${entity.keyColumns.map(() => "?").join(", ")})`,
        bindings: after,
      };

/** When the alarm should next sweep tombstones, or `null` if there's nothing to sweep. */
export const nextTombstoneSweepAt = (sql: StoreSql, policy = tombstonePolicy): number | null => {
  const pass = readPass(sql);
  if (pass !== null) return pass.steppedAt + policy.stepInterval;
  const oldest = sql.exec("SELECT min(at) AS at FROM tombstones")[0]?.["at"];
  return typeof oldest === "number" ? oldest + policy.delay : null;
};

/**
 * Removes tombstoned rows from up to `chunkRows` rows of one table, starting a pass if one is due.
 * When a pass has covered every table, the tombstones from before it started go: their rows are
 * gone. Returns whether a pass is still going.
 */
export const sweepTombstones = (
  sql: StoreSql,
  registry: ReadonlyArray<Entity>,
  now: number,
  policy = tombstonePolicy,
): boolean =>
  sql.transaction(() => {
    const keyed = registry.filter((entity) => entity.key.length > 0);
    let pass = readPass(sql);
    if (pass === null) {
      const due = nextTombstoneSweepAt(sql, policy);
      if (due === null || due > now) return false;
      pass = { entity: 0, after: null, startedAt: now, steppedAt: now };
    }
    const entity = keyed[pass.entity];
    if (entity === undefined) {
      sql.exec("DELETE FROM tombstones WHERE at < ?", pass.startedAt);
      savePass(sql, null);
      return false;
    }
    const next = (after: ReadonlyArray<SqlValue> | null): Pass =>
      after === null
        ? { entity: pass.entity + 1, after: null, startedAt: pass.startedAt, steppedAt: now }
        : { ...pass, after, steppedAt: now };
    const due = sql.exec(
      "SELECT 1 FROM tombstones WHERE entity = ? AND at < ? LIMIT 1",
      entity.name,
      pass.startedAt,
    );
    if (due.length === 0) {
      savePass(sql, next(null));
      return true;
    }
    const from = afterKey(entity, pass.after);
    // The chunk's last row, or none if this is the table's last chunk.
    const last = sql.exec(
      `SELECT ${keyList(entity)} FROM "${entity.name}" WHERE ${from.where}
        ORDER BY ${keyList(entity)} LIMIT 1 OFFSET ?`,
      ...from.bindings,
      policy.chunkRows - 1,
    )[0];
    const lastKey = last === undefined ? null : entity.keyColumns.map((column) => last[column]!);
    const through =
      lastKey === null
        ? { where: "TRUE", bindings: [] as ReadonlyArray<SqlValue> }
        : {
            where: `(${keyList(entity)}) <= (${entity.keyColumns.map(() => "?").join(", ")})`,
            bindings: lastKey,
          };
    sql.exec(
      `DELETE FROM "${entity.name}" WHERE ${from.where} AND ${through.where}
        AND id IN (SELECT id FROM tombstones WHERE entity = ? AND at < ?)`,
      ...from.bindings,
      ...through.bindings,
      entity.name,
      pass.startedAt,
    );
    savePass(sql, next(lastKey));
    return true;
  });
