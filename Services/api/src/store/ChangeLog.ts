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
 * A group's rows written at once at most, as JSON (`applyMutations`): each row's values, and its
 * copy in the change log counted twice for escaping. UTF-8 takes at most 3 bytes a character, so
 * the parameters stay below SQLite's 2 MB limit for a string whatever the records.
 */
export const writeBytes = 256 * 1024;

/** A record as the change log serves it: its ID and every field, from its columns' values. */
const toRow = (
  entity: Entity,
  id: string,
  values: ReadonlyArray<SqlValue>,
): Record<string, Schema.Json> => {
  const row: Record<string, Schema.Json> = { id };
  entity.fields.forEach(({ field, type }, position) => {
    row[field] = fromColumnValue(type, values[position]);
  });
  return row;
};

/**
 * Whether upserts' changes carry a copy of their row (`changes.row`) as well as their key (store
 * migration 17). Code from before it can't serve changes without one, so copies stay until the
 * oldest version a rollback can reach reads both (`docs/SYNC.md`).
 */
export const logsRowCopies = true;

/** A record's key fields' values and ID as one string, to match stored rows to records. */
const recordKey = (values: ReadonlyArray<SqlValue>) => JSON.stringify(values);

/**
 * The stored rows of `keys`, a JSON array of `[...key fields' values, id]` arrays, by
 * `recordKey`: a table with key fields can hold the same ID under two keys.
 */
const selectStored = (sql: StoreSql, entity: Entity, keys: string): Map<string, SqlRow> => {
  const stored = new Map<string, SqlRow>();
  for (const row of sql.exec(entity.statements.select, keys)) {
    stored.set(recordKey(entity.keyColumns.map((column) => row[column] ?? null)), row);
  }
  return stored;
};

/**
 * The current rows of the records whose upserts were logged without a copy (store migration 17),
 * by `seq`: read from their tables in groups, by key and ID. A record that's gone, or tombstoned,
 * has none.
 */
const readLoggedRows = (
  sql: StoreSql,
  entities: ReadonlyMap<string, Entity>,
  logged: ReadonlyArray<SqlRow>,
): Map<number, Record<string, Schema.Json>> => {
  const wanted = new Map<Entity, Array<SqlRow>>();
  for (const change of logged) {
    if (change["op"] !== "upsert" || change["row"] !== "") continue;
    const entity = entities.get(change["entity"] as string);
    if (entity === undefined) continue;
    const changes = wanted.get(entity) ?? [];
    changes.push(change);
    wanted.set(entity, changes);
  }
  const rows = new Map<number, Record<string, Schema.Json>>();
  if (wanted.size === 0) return rows;
  const anyTombstones = sql.exec("SELECT 1 FROM tombstones LIMIT 1").length > 0;
  for (const [entity, changes] of wanted) {
    for (let start = 0; start < changes.length; start += upsertGroupSize) {
      const group = changes.slice(start, start + upsertGroupSize);
      const records = group.map((change) => [
        ...(change["key"] === null ? [] : (JSON.parse(change["key"] as string) as Array<SqlValue>)),
        change["id"] as string,
      ]);
      const keys = JSON.stringify(records);
      const stored = selectStored(sql, entity, keys);
      const tombstoned = new Set<string>();
      if (entity.key.length > 0 && anyTombstones) {
        const rows = sql.exec(
          `SELECT id FROM tombstones
            WHERE entity = ? AND id IN (SELECT value ->> '$[#-1]' FROM json_each(?))`,
          entity.name,
          keys,
        );
        for (const row of rows) tombstoned.add(row["id"] as string);
      }
      group.forEach((change, position) => {
        const id = change["id"] as string;
        const record = stored.get(recordKey(records[position]!));
        if (record === undefined || tombstoned.has(id)) return;
        const values = entity.fields.map(({ column }) => record[column] ?? null);
        rows.set(change["seq"] as number, toRow(entity, id, values));
      });
    }
  }
  return rows;
};

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
 * - An upsert's change keeps the record's key (`key`, and its ID), and a copy of its row while
 *   `copyRows` (`logsRowCopies`). Without one, `readChanges` serves it with the whole record as
 *   it is now. Rolling the server back past an entity schema change therefore needs a new epoch
 *   (see `docs/SYNC.md`).
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
  copyRows = logsRowCopies,
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
      let appended: boolean;
      if (entity.key.length > 0) {
        appended =
          sql.exec(
            `INSERT INTO tombstones (entity, id, at) VALUES (?, ?, ?)
              ON CONFLICT (entity, id) DO NOTHING RETURNING id`,
            entity.name,
            mutation.id,
            at,
          ).length > 0;
        if (appended) tombstones = true;
      } else {
        appended =
          entity.statements.delete !== undefined &&
          sql.exec(entity.statements.delete, mutation.id).length > 0;
      }
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
     * was before the group. Each step runs once for the whole group, or once per `writeBytes` of
     * rows. A mutation that can't be applied throws when its turn comes, so the first one is
     * reported, as one at a time would.
     */
    const applyUpserts = (entity: Entity, group: ReadonlyArray<number>) => {
      type Decoded = {
        readonly index: number;
        readonly id: string;
        readonly set: Readonly<Record<string, Schema.Json>>;
        readonly keyValues: ReadonlyArray<SqlValue>;
      };
      // Decoded up to the first that can't be: the ones before it are still checked against
      // their stored records, in case one of them fails first.
      const decoded: Array<Decoded> = [];
      let failure: InvalidMutation | undefined;
      for (const index of group) {
        const mutation = mutations[index] as Mutation & { readonly op: "upsert" };
        if (!entity.isValidId(mutation.id)) {
          failure = new InvalidMutation({
            index,
            message: `Invalid ${entity.name} ID ${mutation.id}`,
          });
          break;
        }
        const fields = entity.decodeFields(mutation.row);
        if (Result.isFailure(fields)) {
          failure = new InvalidMutation({ index, message: fields.failure.message });
          break;
        }
        const set = fields.success;
        const keyValues: Array<SqlValue> = [];
        for (const field of entity.key) {
          const value = set[field];
          if (value === undefined || value === null) {
            failure = new InvalidMutation({ index, message: `Missing ${field}` });
            break;
          }
          keyValues.push(value as SqlValue);
        }
        if (failure !== undefined) break;
        decoded.push({ index, id: mutation.id, set, keyValues });
      }
      let stored = new Map<string, SqlRow>();
      // A record deleted earlier, whose row may not be removed yet, comes back as a new one.
      const revived = new Set<string>();
      if (decoded.length > 0) {
        const keys = JSON.stringify(decoded.map(({ id, keyValues }) => [...keyValues, id]));
        stored = selectStored(sql, entity, keys);
        if (entity.key.length > 0 && hasTombstones()) {
          const revivedRows = sql.exec(
            `DELETE FROM tombstones
              WHERE entity = ? AND id IN (SELECT value ->> '$[#-1]' FROM json_each(?))
              RETURNING id`,
            entity.name,
            keys,
          );
          for (const row of revivedRows) revived.add(row["id"] as string);
          // Those may have been the last: looked up again when it next matters.
          if (revived.size > 0) tombstones = undefined;
        }
      }
      // Each row's JSON, joined into the statement's array parameter when it's written.
      let upserts: Array<string> = [];
      let changes: Array<readonly [number, string, string, string | null]> = [];
      let bytes = 0;
      const write = () => {
        if (upserts.length === 0) return;
        sql.exec(entity.statements.upsert, `[${upserts.join(",")}]`);
        sql.exec(
          `INSERT INTO changes (seq, entity, id, op, row, key, at)
            SELECT value ->> 0, ?, value ->> 1, 'upsert', value ->> 2, value ->> 3, ?
            FROM json_each(?)`,
          entity.name,
          at,
          JSON.stringify(changes),
        );
        upserts = [];
        changes = [];
        bytes = 0;
      };
      for (const { index, id, set, keyValues } of decoded) {
        const before = revived.has(id) ? undefined : stored.get(recordKey([...keyValues, id]));
        const values = entity.fields.map(({ field, column, type }) =>
          field in set ? toColumnValue(type, set[field] ?? null) : (before?.[column] ?? null),
        );
        const missing = entity.fields.find(
          ({ type }, position) => !type.nullable && values[position] === null,
        );
        if (missing !== undefined) {
          throw new InvalidMutation({ index, message: `Missing ${missing.field}` });
        }
        if (entity.checkRow !== undefined) {
          const invalid = entity.checkRow(id, toRow(entity, id, values));
          if (invalid !== undefined) throw new InvalidMutation({ index, message: invalid });
        }
        if (
          before !== undefined &&
          sameValues(
            values,
            entity.fields.map(({ column }) => before[column] ?? null),
          )
        ) {
          continue;
        }
        const upsert = JSON.stringify([id, ...values]);
        const copy = copyRows ? JSON.stringify(toRow(entity, id, values)) : "";
        const key = entity.key.length > 0 ? JSON.stringify(keyValues) : null;
        upserts.push(upsert);
        changes.push([++head, id, copy, key]);
        bytes += upsert.length + copy.length * 2 + (key?.length ?? 0);
        if (bytes >= writeBytes) write();
      }
      if (failure !== undefined) throw failure;
      write();
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
 * in one transaction, so `epoch`, `head` and the page agree. Upserts come with their records'
 * current rows (`readLoggedRows`); one whose record is gone is served as a delete.
 */
export const readChanges = (
  sql: StoreSql,
  entities: ReadonlyMap<string, Entity>,
  after: number,
  limit: number,
): ChangesPage | ChangesCompacted =>
  sql.transaction(() => {
    if (after < readHorizon(sql)) return new ChangesCompacted({ reason: "compacted" });
    const logged = sql.exec(
      "SELECT seq, entity, id, op, row, key, at FROM changes WHERE seq > ? ORDER BY seq LIMIT ?",
      after,
      limit,
    );
    const rows = readLoggedRows(sql, entities, logged);
    const changes = logged.flatMap((change): Array<Change> => {
      const seq = change["seq"] as number;
      const base = {
        seq,
        entity: change["entity"] as string,
        id: change["id"] as string,
        at: change["at"] as number,
      };
      const copy = change["row"];
      if (change["op"] === "delete") return [{ ...base, op: "delete" }];
      if (typeof copy === "string" && copy !== "") {
        return [{ ...base, op: "upsert", row: JSON.parse(copy) as Record<string, Schema.Json> }];
      }
      // An entity this code doesn't know (e.g. after a rollback) has no row to read: left out,
      // as clients that don't know it ignore it.
      if (!entities.has(base.entity)) return [];
      // Its record is gone (deleted since, by a later change): a delete gets the same result.
      const row = rows.get(seq);
      return [row === undefined ? { ...base, op: "delete" } : { ...base, op: "upsert", row }];
    });
    const head = readHead(sql);
    // The log's, not the page's: a change left out still moves the cursor.
    const next = (logged.at(-1)?.["seq"] as number | undefined) ?? after;
    return { epoch: readEpoch(sql), changes, next, head, hasMore: next < head };
  });
