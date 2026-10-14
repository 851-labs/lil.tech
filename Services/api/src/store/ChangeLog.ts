import { columnName, type Entity, type EntityRow, fromColumns, toColumns } from "./Entities.ts";
import type { SqlValue, StoreSql } from "./StoreSql.ts";

/** The newest `seq` in the store's change log, or 0 before the first change. */
export const readHead = (sql: StoreSql): number =>
  Number(sql.exec("SELECT value FROM meta WHERE key = 'head'")[0]?.["value"] ?? 0);

export interface AppliedMutations {
  /** The store's `head` afterwards: the `seq` of the last change appended, if any. */
  readonly head: number;
  /** How many changes were appended. */
  readonly appended: number;
}

const sameValues = (a: ReadonlyArray<SqlValue>, b: ReadonlyArray<SqlValue>) =>
  a.length === b.length && a.every((value, index) => value === b[index]);

/**
 * Writes `upserts` (full rows) and then `deletes` to the entity's table and appends one change per
 * record that actually changed, all in one synchronous transaction (`docs/SYNC.md`).
 *
 * - `head` is read and advanced inside the transaction, so `seq` values have no gaps even when
 *   calls interleave between transactions.
 * - An upsert that leaves the stored row unchanged, or a delete of a record that doesn't exist,
 *   appends nothing, so retries don't grow the log.
 * - The change's `row` is re-read from the stored columns, so the log carries exactly what the
 *   table holds.
 */
export const applyMutations = (
  sql: StoreSql,
  entity: Entity,
  upserts: ReadonlyArray<EntityRow>,
  deletes: ReadonlyArray<string>,
  at: number,
): AppliedMutations =>
  sql.transaction(() => {
    const columns = Object.keys(entity.fields).map(columnName);
    const select = `SELECT ${["id", ...columns].join(", ")} FROM ${entity.name} WHERE id = ?`;
    const upsert = `INSERT INTO ${entity.name} (${["id", ...columns].join(", ")})
      VALUES (${["?", ...columns.map(() => "?")].join(", ")})
      ON CONFLICT (id) DO UPDATE SET ${columns.map((column) => `${column} = excluded.${column}`).join(", ")}`;
    const append = (seq: number, id: string, op: "upsert" | "delete", row: string | null) =>
      sql.exec(
        "INSERT INTO changes (seq, entity, id, op, row, at) VALUES (?, ?, ?, ?, ?, ?)",
        seq,
        entity.name,
        id,
        op,
        row,
        at,
      );

    const start = readHead(sql);
    let head = start;
    for (const row of upserts) {
      const values = toColumns(entity, row);
      const stored = sql.exec(select, row.id)[0];
      if (
        stored !== undefined &&
        sameValues(toColumns(entity, fromColumns(entity, stored)), values)
      ) {
        continue;
      }
      sql.exec(upsert, row.id, ...values);
      const written = sql.exec(select, row.id)[0];
      if (written === undefined) throw new Error(`${entity.name} ${row.id} vanished`);
      append(++head, row.id, "upsert", JSON.stringify(fromColumns(entity, written)));
    }
    for (const id of deletes) {
      if (sql.exec(`DELETE FROM ${entity.name} WHERE id = ? RETURNING id`, id).length === 0) {
        continue;
      }
      append(++head, id, "delete", null);
    }
    if (head !== start) {
      sql.exec(
        "INSERT INTO meta (key, value) VALUES ('head', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        head,
      );
    }
    return { head, appended: head - start };
  });
