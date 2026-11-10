import type { Schema } from "effect";
import { applyMutations, readHead, readMeta } from "../store/ChangeLog.ts";
import { InvalidMutation, type Mutation } from "../store/Changes.ts";
import { comparedToKey, type Entity, fromColumnValue, keyList } from "../store/Entities.ts";
import type { SqlValue, StoreSql } from "../store/StoreSql.ts";
import { keptValue, metadataFields } from "./HealthMetadata.ts";

// Drops what lil health no longer keeps (851-4152, `src/health/HealthMetadata.ts`) from the
// records a store already has: metadata keys and device properties older iPhones uploaded. The
// store's alarm goes through every record of the entities with metadata or a device, a chunk at a
// time in primary key order, and rewrites the ones that change through the change log, so every
// Mac's copy is cleaned by its next pull, as any other change is (`docs/sync/protocol.md`). No new
// epoch, so no Mac bootstraps again, and later snapshots are written from the cleaned records.

/**
 * What the store's records were last cleaned for. Bump it when lil health keeps less (a key or
 * property dropped), so every store goes through its records again. 1: 851-4152.
 */
export const metadataPolicyVersion = 1;

/** Records looked at per alarm, in one transaction. */
export const metadataCleanupChunk = 5_000;

/**
 * The time between cleanup alarms, so a large store's cleanup doesn't monopolize it, or keep its
 * Macs pulling every second: as retiring a device does (`retireStepInterval`).
 */
export const metadataCleanupInterval = 5_000;

const policyKey = "metadata_policy";
const cursorKey = "metadata_cleanup";

/** Where the cleanup is: the entity, the last record's key looked at, and records changed so far. */
interface Cursor {
  readonly entity: string;
  readonly after: ReadonlyArray<SqlValue> | null;
  readonly changed: number;
  /** Records a check refused (`applyCleaned`), kept as they were. Missing from early cursors. */
  readonly skipped?: number;
}

/** Whether the store's records still need cleaning for `metadataPolicyVersion`. */
export const metadataCleanupPending = (sql: StoreSql) =>
  readMeta(sql, policyKey, 0) < metadataPolicyVersion;

/** Marks the store's records clean, e.g. a store with none yet. */
export const markMetadataClean = (sql: StoreSql) => {
  sql.exec(
    `INSERT INTO meta (key, value) VALUES (?, ?)
      ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
    policyKey,
    metadataPolicyVersion,
  );
  sql.exec("DELETE FROM meta WHERE key = ?", cursorKey);
};

/** A store that was never written has nothing to clean. A deleted one is left as it is. */
export const markNewStoreMetadataClean = (sql: StoreSql) => {
  if (readHead(sql) === 0 && readMeta(sql, "deleted", 0) !== 1 && metadataCleanupPending(sql)) {
    markMetadataClean(sql);
  }
};

const readCursor = (sql: StoreSql): Cursor | null => {
  const value = sql.exec("SELECT value FROM meta WHERE key = ?", cursorKey)[0]?.["value"];
  return typeof value === "string" ? (JSON.parse(value) as Cursor) : null;
};

/**
 * Applies the cleanup's upserts, leaving out any a check refuses (a check made stricter since the
 * record was written: `Entity.checkRow`), so one such record can't hold the pass up. Returns the
 * changes appended and the records left out.
 */
const applyCleaned = (
  sql: StoreSql,
  entities: ReadonlyMap<string, Entity>,
  mutations: ReadonlyArray<Mutation>,
  at: number,
) => {
  let left = mutations;
  let skipped = 0;
  while (left.length > 0) {
    try {
      return { appended: applyMutations(sql, entities, left, at).appended, skipped };
    } catch (error) {
      if (!(error instanceof InvalidMutation)) throw error;
      left = left.filter((_, index) => index !== error.index);
      skipped += 1;
    }
  }
  return { appended: 0, skipped };
};

/**
 * Looks at up to `limit` records from where the last step stopped, rewrites those holding a
 * metadata key or device property lil health doesn't keep, and moves the cursor on, in one
 * transaction. Tombstoned records are left alone, since an upsert would bring them back, and so
 * is one a check refuses (`applyCleaned`). Once every record is done, marks the store clean.
 * Returns what it did: records looked at, changed and left out, and whether it's finished, with
 * the whole pass's counts.
 */
export const metadataCleanupStep = (
  sql: StoreSql,
  registry: ReadonlyArray<Entity>,
  at: number,
  limit = metadataCleanupChunk,
) =>
  sql.transaction(() => {
    const entitiesByName = new Map(registry.map((entity) => [entity.name, entity]));
    const targets = registry.filter((entity) => metadataFields(entity).length > 0);
    const cursor = readCursor(sql);
    let index = Math.max(
      0,
      targets.findIndex((entity) => entity.name === cursor?.entity),
    );
    let after = cursor === null || targets[index]?.name !== cursor.entity ? null : cursor.after;
    let looked = 0;
    let changed = 0;
    let skipped = 0;
    while (index < targets.length && looked < limit) {
      const entity = targets[index]!;
      const fields = metadataFields(entity);
      const wanted = limit - looked;
      const from = comparedToKey(entity, ">", after);
      // Only entities with key fields have tombstones (`src/store/Tombstones.ts`).
      const live =
        entity.key.length > 0
          ? "AND NOT EXISTS (SELECT 1 FROM tombstones WHERE entity = ? AND tombstones.id = record.id)"
          : "";
      const rows = sql.rows(
        `SELECT ${keyList(entity)}, ${fields.map(({ column }) => `"${column}"`).join(", ")}
          FROM "${entity.name}" AS record
          WHERE ${from.where} ${live}
          ORDER BY ${keyList(entity)}
          LIMIT ?`,
        ...from.bindings,
        ...(live === "" ? [] : [entity.name]),
        wanted,
      );
      looked += rows.length;
      const mutations: Array<Mutation> = [];
      for (const row of rows) {
        const set: Record<string, Schema.Json> = {};
        fields.forEach(({ field, type }, position) => {
          const stored = row[entity.keyColumns.length + position];
          if (stored === null || stored === undefined) return;
          const value = fromColumnValue(type, stored);
          const kept = keptValue(field, value);
          if (JSON.stringify(kept) !== JSON.stringify(value)) set[field] = kept;
        });
        if (Object.keys(set).length === 0) continue;
        // Upserts find a record by its key fields, which lead the primary key, and its ID.
        entity.key.forEach((field, position) => {
          set[field] = row[position] as Schema.Json;
        });
        const id = row[entity.keyColumns.length - 1] as string;
        mutations.push({ entity: entity.name, op: "upsert", id, row: set });
      }
      if (mutations.length > 0) {
        const applied = applyCleaned(sql, entitiesByName, mutations, at);
        changed += applied.appended;
        skipped += applied.skipped;
      }
      if (rows.length < wanted) {
        index += 1;
        after = null;
      } else {
        after = rows.at(-1)!.slice(0, entity.keyColumns.length);
      }
    }
    const total = (cursor?.changed ?? 0) + changed;
    const totalSkipped = (cursor?.skipped ?? 0) + skipped;
    const finished = index >= targets.length;
    if (finished) {
      markMetadataClean(sql);
    } else {
      const next: Cursor = {
        entity: targets[index]!.name,
        after,
        changed: total,
        skipped: totalSkipped,
      };
      sql.exec(
        `INSERT INTO meta (key, value) VALUES (?, ?)
          ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
        cursorKey,
        JSON.stringify(next),
      );
    }
    return { looked, changed, skipped, finished, total, totalSkipped };
  });
