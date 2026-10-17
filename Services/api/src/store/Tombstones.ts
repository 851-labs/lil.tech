import { comparedToKey, type Entity, keyList } from "./Entities.ts";
import { deferWhileIngesting, type SnapshotPolicy, snapshotPolicy } from "./Snapshots.ts";
import type { SqlValue, StoreSql } from "./StoreSql.ts";

// Records of an entity with key fields (`Entity.key`) are stored in their key's order, so one
// can't be found by its ID alone. A delete leaves a tombstone instead (`applyMutations`), and the
// change log has the delete at once. The store's alarm removes the rows later, in passes over
// each such table a chunk at a time. Until then, reads skip tombstoned records (`docs/SYNC.md`).

export const tombstonePolicy = {
  /**
   * How long the oldest tombstone waits before a pass starts. A pass reads every row of the
   * tables it covers, so it runs at most about daily, however few tombstones there are.
   */
  delay: 24 * 60 * 60 * 1000,
  /** Rows looked at per alarm, in one transaction. */
  chunkRows: 50_000,
  /** The time between a pass's alarms, so it doesn't monopolize the store. */
  stepInterval: 2_000,
};

export type TombstonePolicy = typeof tombstonePolicy;

/**
 * A pass in progress: the table it's on (entities are swept in name order), the last key it
 * looked at, and when it started.
 */
interface Pass {
  readonly entity: string;
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

/**
 * When the alarm should next sweep tombstones, or `null` if there's nothing to sweep. Like
 * snapshots, it waits while the store is taking in uploads (`deferWhileIngesting`).
 */
export const nextTombstoneSweepAt = (
  sql: StoreSql,
  now: number,
  policy = tombstonePolicy,
  quiet: SnapshotPolicy = snapshotPolicy,
): number | null => {
  const pass = readPass(sql);
  const oldest = sql.exec("SELECT min(at) AS at FROM tombstones")[0]?.["at"];
  const due =
    pass !== null
      ? pass.steppedAt + policy.stepInterval
      : typeof oldest === "number"
        ? oldest + policy.delay
        : null;
  return due === null ? null : deferWhileIngesting(sql, due, now, quiet);
};

/**
 * If a sweep is due, removes tombstoned rows from up to `chunkRows` rows of one table, starting a
 * pass if there's none. Once a pass has covered a table, its tombstones from before the pass
 * started go: their rows are gone. Returns whether a pass is still going.
 */
export const sweepTombstones = (
  sql: StoreSql,
  registry: ReadonlyArray<Entity>,
  now: number,
  policy = tombstonePolicy,
  quiet: SnapshotPolicy = snapshotPolicy,
): boolean =>
  sql.transaction(() => {
    const current = readPass(sql);
    if (nextTombstoneSweepAt(sql, now, policy, quiet) !== now) return current !== null;
    const keyed = registry
      .filter((entity) => entity.key.length > 0)
      .sort((a, b) => (a.name < b.name ? -1 : 1));
    const first = keyed[0];
    const pass = current ?? {
      entity: first?.name ?? "",
      after: null,
      startedAt: now,
      steppedAt: now,
    };
    /** The pass is over: tombstones of entities without key fields any more can't be swept. */
    const end = () => {
      sql.exec(
        `DELETE FROM tombstones WHERE at < ?
          AND entity NOT IN (${keyed.map(() => "?").join(", ")})`,
        pass.startedAt,
        ...keyed.map((candidate) => candidate.name),
      );
      savePass(sql, null);
      return false;
    };
    // Its table, or the next one if a deploy removed it; the cursor only counts for its own.
    const entity = keyed.find((candidate) => candidate.name >= pass.entity);
    const after = entity?.name === pass.entity ? pass.after : null;
    if (entity === undefined) return end();
    const finished = () => {
      sql.exec("DELETE FROM tombstones WHERE entity = ? AND at < ?", entity.name, pass.startedAt);
      const next = keyed.find((candidate) => candidate.name > entity.name);
      if (next === undefined) return end();
      savePass(sql, { entity: next.name, after: null, startedAt: pass.startedAt, steppedAt: now });
      return true;
    };
    const due = sql.exec(
      "SELECT 1 FROM tombstones WHERE entity = ? AND at < ? LIMIT 1",
      entity.name,
      pass.startedAt,
    );
    if (due.length === 0) return finished();

    const from = comparedToKey(entity, ">", after);
    // The chunk's last row, or none if this is the table's last chunk.
    const last = sql.exec(
      `SELECT ${keyList(entity)} FROM "${entity.name}" WHERE ${from.where}
        ORDER BY ${keyList(entity)} LIMIT 1 OFFSET ?`,
      ...from.bindings,
      policy.chunkRows - 1,
    )[0];
    const lastKey =
      last === undefined ? null : entity.keyColumns.map((column) => last[column] ?? null);
    const through = comparedToKey(entity, "<=", lastKey);
    sql.exec(
      `DELETE FROM "${entity.name}" WHERE ${from.where} AND ${through.where}
        AND id IN (SELECT id FROM tombstones WHERE entity = ? AND at < ?)`,
      ...from.bindings,
      ...through.bindings,
      entity.name,
      pass.startedAt,
    );
    if (lastKey === null) return finished();
    savePass(sql, { ...pass, entity: entity.name, after: lastKey, steppedAt: now });
    return true;
  });
