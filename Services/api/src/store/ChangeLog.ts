import { Result, type Schema } from "effect";
import {
  type Change,
  ChangesCompacted,
  type ChangesPage,
  InvalidMutation,
  type Mutation,
} from "./Changes.ts";
import { type Entity, fromColumnValue, toColumnValue } from "./Entities.ts";
import type { SqlRow, SqlValue, StoreSql } from "./StoreSql.ts";

export const readMeta = (sql: StoreSql, key: string, fallback: number): number =>
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
 * Upserts applied together at most (`applyMutations`). Their rows go to SQLite as one JSON
 * parameter, which stays far below its 2 MB limit for a string.
 */
export const upsertGroupSize = 500;

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
 * - For an entity with key fields (`Entity.key`), upserts find the record by them and its ID, so
 *   they must include them. A delete leaves a tombstone, and the record's row is removed later
 *   (`src/store/Tombstones.ts`): it can't be found by its ID alone. Its first delete is appended
 *   whether or not the record exists; deleting it again appends nothing. An upsert after the
 *   delete brings it back, as a new record.
 */
export const applyMutations = (
  sql: StoreSql,
  entities: ReadonlyMap<string, Entity>,
  mutations: ReadonlyArray<Mutation>,
  at: number,
): AppliedMutations =>
  sql.transaction(() => {
    const start = readHead(sql);
    let head = start;
    // Looked up once, and only for entities with key fields: most transactions have none.
    let tombstones: boolean | undefined;
    const hasTombstones = () =>
      (tombstones ??= sql.exec("SELECT 1 FROM tombstones LIMIT 1").length > 0);

    const entityOf = (index: number, mutation: Mutation) => {
      const entity = entities.get(mutation.entity);
      if (entity === undefined) {
        throw new InvalidMutation({ index, message: `Unknown entity ${mutation.entity}` });
      }
      return entity;
    };

    const applyDelete = (index: number, entity: Entity, mutation: Mutation) => {
      if (!entity.isValidId(mutation.id)) {
        throw new InvalidMutation({ index, message: `Invalid ${entity.name} ID ${mutation.id}` });
      }
      const appended =
        entity.key.length > 0
          ? sql.exec(
              `INSERT INTO tombstones (entity, id, at) VALUES (?, ?, ?)
                ON CONFLICT (entity, id) DO NOTHING RETURNING id`,
              entity.name,
              mutation.id,
              at,
            ).length > 0
          : entity.statements.delete !== undefined &&
            sql.exec(entity.statements.delete, mutation.id).length > 0;
      if (entity.key.length > 0 && appended) tombstones = true;
      if (appended) {
        sql.exec(
          "INSERT INTO changes (seq, entity, id, op, row, at) VALUES (?, ?, ?, 'delete', NULL, ?)",
          ++head,
          entity.name,
          mutation.id,
          at,
        );
      }
    };

    /**
     * Applies a group of upserts to one entity, with no ID twice, so each finds its record as it
     * was before the group. Each step runs once for the whole group. A mutation that can't be
     * applied throws when its turn comes, so the first one is reported, as one at a time would.
     */
    const applyUpserts = (entity: Entity, group: ReadonlyArray<number>) => {
      const decoded = group.map((index) => {
        const mutation = mutations[index] as Mutation & { readonly op: "upsert" };
        if (!entity.isValidId(mutation.id)) {
          return { index, error: `Invalid ${entity.name} ID ${mutation.id}` } as const;
        }
        const fields = entity.decodeFields(mutation.row);
        if (Result.isFailure(fields)) return { index, error: fields.failure.message } as const;
        const set = fields.success;
        const keyValues: Array<SqlValue> = [];
        for (const field of entity.key) {
          const value = set[field];
          if (value === undefined || value === null) {
            return { index, error: `Missing ${field}` } as const;
          }
          keyValues.push(value as SqlValue);
        }
        return { index, id: mutation.id, set, keyValues } as const;
      });
      const valid = decoded.flatMap((record) => ("error" in record ? [] : [record]));
      const stored = new Map<string, SqlRow>();
      // A record deleted earlier, whose row may not be removed yet, comes back as a new one.
      const revived = new Set<string>();
      if (valid.length > 0) {
        const keys = JSON.stringify(valid.map(({ id, keyValues }) => [...keyValues, id]));
        for (const row of sql.exec(entity.statements.select, keys)) {
          stored.set(row["id"] as string, row);
        }
        if (entity.key.length > 0 && hasTombstones()) {
          const revivedRows = sql.exec(
            `DELETE FROM tombstones WHERE entity = ? AND id IN (SELECT value FROM json_each(?))
              RETURNING id`,
            entity.name,
            JSON.stringify(valid.map(({ id }) => id)),
          );
          for (const row of revivedRows) revived.add(row["id"] as string);
        }
      }
      const upserts: Array<ReadonlyArray<SqlValue>> = [];
      const changes: Array<readonly [number, string, string]> = [];
      for (const record of decoded) {
        if ("error" in record) {
          throw new InvalidMutation({ index: record.index, message: record.error });
        }
        const { index, id, set } = record;
        const before = revived.has(id) ? undefined : stored.get(id);
        const values = entity.fields.map(({ field, column, type }) =>
          field in set ? toColumnValue(type, set[field] ?? null) : (before?.[column] ?? null),
        );
        const missing = entity.fields.find(
          ({ type }, position) => !type.nullable && values[position] === null,
        );
        if (missing !== undefined) {
          throw new InvalidMutation({ index, message: `Missing ${missing.field}` });
        }
        const row: Record<string, Schema.Json> = { id };
        entity.fields.forEach(({ field, type }, position) => {
          row[field] = fromColumnValue(type, values[position]);
        });
        const invalid = entity.checkRow?.(id, row);
        if (invalid !== undefined) throw new InvalidMutation({ index, message: invalid });
        if (
          before !== undefined &&
          sameValues(
            values,
            entity.fields.map(({ column }) => before[column] ?? null),
          )
        ) {
          continue;
        }
        upserts.push([id, ...values]);
        changes.push([++head, id, JSON.stringify(row)]);
      }
      if (upserts.length === 0) return;
      sql.exec(entity.statements.upsert, JSON.stringify(upserts));
      sql.exec(
        `INSERT INTO changes (seq, entity, id, op, row, at)
          SELECT value ->> 0, ?, value ->> 1, 'upsert', value ->> 2, ? FROM json_each(?)`,
        entity.name,
        at,
        JSON.stringify(changes),
      );
    };

    let index = 0;
    while (index < mutations.length) {
      const mutation = mutations[index]!;
      const entity = entityOf(index, mutation);
      if (mutation.op === "delete") {
        applyDelete(index, entity, mutation);
        index += 1;
        continue;
      }
      // This upsert and the ones right after it to the same entity, until an ID repeats.
      const group: Array<number> = [];
      const ids = new Set<string>();
      for (let next = index; next < mutations.length && group.length < upsertGroupSize; next += 1) {
        const candidate = mutations[next]!;
        if (
          candidate.op !== "upsert" ||
          candidate.entity !== mutation.entity ||
          ids.has(candidate.id)
        ) {
          break;
        }
        ids.add(candidate.id);
        group.push(next);
      }
      applyUpserts(entity, group);
      index += group.length;
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
