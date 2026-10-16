import { Effect } from "effect";
import type { Entity } from "./Entities.ts";
import { readMeta } from "./ChangeLog.ts";
import type { StoreSql } from "./StoreSql.ts";

// Deletes the store's health blobs (`src/health/HealthBlobs.ts`) that no record refers to any
// more, once they've been unreferenced for `blobGracePeriodMs`. That's longer than Durable Object
// point-in-time recovery (30 days), so a restored store never refers to a deleted blob. Runs from
// the store's alarm at most once a day (`docs/SYNC.md`).

const day = 24 * 60 * 60 * 1000;
export const blobGracePeriodMs = 35 * day;
export const blobSweepIntervalMs = day;
/** Blobs deleted per sweep; a sweep with more due runs again a minute later. */
export const blobSweepBatch = 1000;

/** The user's blobs in R2 (the Worker's `HealthBlobs` bucket). */
export interface BlobFiles {
  /** Every object under `prefix`, with when it was uploaded (Unix milliseconds). */
  readonly list: (
    prefix: string,
  ) => Effect.Effect<ReadonlyArray<{ readonly key: string; readonly uploaded: number }>>;
  readonly delete: (keys: ReadonlyArray<string>) => Effect.Effect<void>;
}

/** Blob files that aren't available, for stores built without them (most tests). */
export const noBlobFiles: BlobFiles = {
  list: () => Effect.succeed([]),
  delete: () => Effect.void,
};

/** Where the user's blobs are in R2, recorded with the first one (`recordHealthBlob`). */
export const readBlobPrefix = (sql: StoreSql): string | null => {
  const value = sql.exec("SELECT value FROM meta WHERE key = 'health_blob_prefix'")[0]?.["value"];
  return typeof value === "string" ? value : null;
};

/** When the next sweep is due, or `null` for a store that never had a blob. */
export const nextBlobSweepAt = (sql: StoreSql): number | null =>
  readBlobPrefix(sql) === null
    ? null
    : readMeta(sql, "health_blob_swept_at", 0) + blobSweepIntervalMs;

/** The SHA-256s records refer to: every entity's blob fields (`defineEntity`'s `blobs`). */
const referencedBlobs = (registry: ReadonlyArray<Entity>) => {
  const selects = registry.flatMap((entity) =>
    entity.blobColumns.map(
      (column) =>
        `SELECT "${column}" AS sha256 FROM "${entity.name}" WHERE "${column}" IS NOT NULL`,
    ),
  );
  return selects.length === 0 ? "SELECT NULL AS sha256 WHERE 0" : selects.join(" UNION ");
};

const setSweptAt = (sql: StoreSql, at: number) =>
  sql.exec(
    `INSERT INTO meta (key, value) VALUES ('health_blob_swept_at', ?)
     ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
    at,
  );

/** After a failed sweep: the next in an hour. */
export const retryBlobSweepLater = (sql: StoreSql, now: number) =>
  setSweptAt(sql, now - blobSweepIntervalMs + 60 * 60 * 1000);

/**
 * One sweep: marks blobs that lost their last reference (and unmarks ones referred to again),
 * deletes those unreferenced for the grace period, and deletes objects under the user's prefix
 * that the store never recorded (an upload whose recording failed) once they're as old.
 *
 * Rows go before objects, each re-checked in the same transaction, so a blob uploaded again or
 * referred to meanwhile is kept. An object whose delete then fails is a stray, deleted later. One
 * race remains: a blob re-uploaded while its object's delete is in flight (it'd have been
 * unreferenced for 35 days) can lose the object. The record's Mac would then fail to download it.
 */
export const sweepBlobs = Effect.fnUntraced(function* (
  sql: StoreSql,
  registry: ReadonlyArray<Entity>,
  files: BlobFiles,
  now: number,
) {
  const prefix = readBlobPrefix(sql);
  if (prefix === null) return;
  const referenced = referencedBlobs(registry);
  const cutoff = now - blobGracePeriodMs;
  const due = sql.transaction(() => {
    sql.exec(
      `UPDATE health_blobs SET unreferenced_since = ?
       WHERE unreferenced_since IS NULL AND sha256 NOT IN (${referenced})`,
      now,
    );
    sql.exec(
      `UPDATE health_blobs SET unreferenced_since = NULL
       WHERE unreferenced_since IS NOT NULL AND sha256 IN (${referenced})`,
    );
    const rows = sql.exec(
      `SELECT sha256, size FROM health_blobs WHERE unreferenced_since <= ?
       ORDER BY unreferenced_since LIMIT ?`,
      cutoff,
      blobSweepBatch,
    );
    for (const row of rows) {
      sql.exec("DELETE FROM health_blobs WHERE sha256 = ?", row["sha256"] as string);
      sql.exec(
        "UPDATE meta SET value = value - ? WHERE key = 'health_blob_bytes'",
        row["size"] as number,
      );
    }
    return rows.map((row) => row["sha256"] as string);
  });
  yield* files.delete(due.map((sha256) => `${prefix}${sha256}`));
  // With more due than one sweep deletes, the next runs a minute later, and the stray pass,
  // which lists every object, waits for the last of them.
  if (due.length === blobSweepBatch) {
    setSweptAt(sql, now - blobSweepIntervalMs + 60_000);
    return;
  }
  const objects = yield* files.list(prefix);
  // Read after listing, which awaits: a blob recorded meanwhile isn't a stray.
  const kept = new Set(
    sql
      .exec(`SELECT sha256 FROM health_blobs UNION ${referenced}`)
      .map((row) => row["sha256"] as string),
  );
  const strays = objects.filter(
    (object) => !kept.has(object.key.slice(prefix.length)) && object.uploaded <= cutoff,
  );
  yield* files.delete(strays.map((object) => object.key));
  setSweptAt(sql, now);
});
