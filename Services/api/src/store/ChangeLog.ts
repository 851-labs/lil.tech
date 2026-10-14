import { Result, type Schema } from "effect";
import {
  type Change,
  ChangesCompacted,
  type ChangesPage,
  InvalidMutation,
  type Mutation,
} from "./Changes.ts";
import { type Entity, fromColumnValue, toColumnValue } from "./Entities.ts";
import type { SqlValue, StoreSql } from "./StoreSql.ts";

const readMeta = (sql: StoreSql, key: string, fallback: number): number =>
  Number(sql.exec("SELECT value FROM meta WHERE key = ?", key)[0]?.["value"] ?? fallback);

/** The newest `seq` in the store's change log, or 0 before the first change. */
export const readHead = (sql: StoreSql) => readMeta(sql, "head", 0);

/** The store's epoch (`docs/SYNC.md`), which starts at 1. */
export const readEpoch = (sql: StoreSql) => readMeta(sql, "epoch", 1);

/** The highest `seq` compaction has deleted, or 0. */
export const readHorizon = (sql: StoreSql) => readMeta(sql, "horizon", 0);

export interface AppliedMutations {
  /** The store's `head` afterwards: the `seq` of the last change appended, if any. */
  readonly head: number;
  /** How many changes were appended. */
  readonly appended: number;
}

const sameValues = (a: ReadonlyArray<SqlValue>, b: ReadonlyArray<SqlValue>) =>
  a.length === b.length && a.every((value, index) => value === b[index]);

/**
 * Applies `mutations` in order and appends one change per record that changed, all in one
 * synchronous transaction (`docs/SYNC.md`). Throws `InvalidMutation` (and writes nothing) if any
 * mutation can't be applied.
 *
 * - `head` is read and advanced inside the transaction, so `seq` values have no gaps even when
 *   calls interleave between transactions.
 * - Upserts merge: fields a row leaves out keep their stored values. A new record needs every
 *   non-nullable field.
 * - An upsert that leaves the stored row unchanged, or a delete of a record that doesn't exist,
 *   appends nothing, so retries don't grow the log.
 * - A change's `row` is the whole record as stored, with every field this code knows. Rolling the
 *   server back past an entity schema change therefore needs a new epoch (see `docs/SYNC.md`).
 */
export const applyMutations = (
  sql: StoreSql,
  entities: ReadonlyMap<string, Entity>,
  mutations: ReadonlyArray<Mutation>,
  at: number,
): AppliedMutations =>
  sql.transaction(() => {
    const append = (seq: number, mutation: Mutation, row: string | null) =>
      sql.exec(
        "INSERT INTO changes (seq, entity, id, op, row, at) VALUES (?, ?, ?, ?, ?, ?)",
        seq,
        mutation.entity,
        mutation.id,
        mutation.op,
        row,
        at,
      );

    const start = readHead(sql);
    let head = start;
    for (const [index, mutation] of mutations.entries()) {
      const entity = entities.get(mutation.entity);
      if (entity === undefined) {
        throw new InvalidMutation({ index, message: `Unknown entity ${mutation.entity}` });
      }
      if (mutation.op === "delete") {
        if (sql.exec(entity.statements.delete, mutation.id).length > 0)
          append(++head, mutation, null);
        continue;
      }

      const decoded = entity.decodeFields(mutation.row);
      if (Result.isFailure(decoded)) {
        throw new InvalidMutation({ index, message: decoded.failure.message });
      }
      const set = decoded.success;
      const stored = sql.exec(entity.statements.select, mutation.id)[0];
      const values = entity.fields.map(({ field, column, type }) =>
        field in set ? toColumnValue(type, set[field] ?? null) : (stored?.[column] ?? null),
      );
      const missing = entity.fields.find(
        ({ type }, position) => !type.nullable && values[position] === null,
      );
      if (missing !== undefined) {
        throw new InvalidMutation({ index, message: `Missing ${missing.field}` });
      }
      if (
        stored !== undefined &&
        sameValues(
          values,
          entity.fields.map(({ column }) => stored[column] ?? null),
        )
      ) {
        continue;
      }
      sql.exec(entity.statements.upsert, mutation.id, ...values);
      const row: Record<string, Schema.Json> = { id: mutation.id };
      entity.fields.forEach(({ field, type }, position) => {
        row[field] = fromColumnValue(type, values[position]);
      });
      append(++head, mutation, JSON.stringify(row));
    }
    if (head !== start) {
      sql.exec(
        "INSERT INTO meta (key, value) VALUES ('head', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        head,
      );
    }
    return { head, appended: head - start };
  });

/**
 * Up to `limit` changes after `after`, or `ChangesCompacted` if some of them were deleted. Reads
 * in one transaction, so `epoch`, `head` and the page agree.
 */
export const readChanges = (
  sql: StoreSql,
  after: number,
  limit: number,
): ChangesPage | ChangesCompacted =>
  sql.transaction(() => {
    if (after < readHorizon(sql)) return new ChangesCompacted({ reason: "compacted" });
    const changes = sql
      .exec(
        "SELECT seq, entity, id, op, row, at FROM changes WHERE seq > ? ORDER BY seq LIMIT ?",
        after,
        limit,
      )
      .map((change): Change => ({
        seq: change["seq"] as number,
        entity: change["entity"] as string,
        id: change["id"] as string,
        op: change["op"] as Change["op"],
        ...(change["row"] === null
          ? {}
          : { row: JSON.parse(change["row"] as string) as Record<string, Schema.Json> }),
        at: change["at"] as number,
      }));
    const head = readHead(sql);
    const next = changes.at(-1)?.seq ?? after;
    return { epoch: readEpoch(sql), changes, next, head, hasMore: next < head };
  });
