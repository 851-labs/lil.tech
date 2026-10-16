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

/**
 * One sweep: marks blobs that lost their last reference (and unmarks ones referred to again),
 * deletes those unreferenced for the grace period, and deletes objects under the user's prefix
 * that the store never recorded (an upload whose recording failed) once they're as old.
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
  sql.transaction(() => {
    sql.exec(
      `UPDATE health_blobs SET unreferenced_since = ?
       WHERE unreferenced_since IS NULL AND sha256 NOT IN (${referenced})`,
      now,
    );
    sql.exec(
      `UPDATE health_blobs SET unreferenced_since = NULL
       WHERE unreferenced_since IS NOT NULL AND sha256 IN (${referenced})`,
    );
  });
  const due = sql.exec(
    `SELECT sha256, size FROM health_blobs WHERE unreferenced_since <= ?
     ORDER BY unreferenced_since LIMIT ?`,
    now - blobGracePeriodMs,
    blobSweepBatch,
  );
  // R2 first: a row left behind is deleted again next time, an object without a row isn't.
  yield* files.delete(due.map((row) => `${prefix}${row["sha256"] as string}`));
  sql.transaction(() => {
    for (const row of due) {
      sql.exec("DELETE FROM health_blobs WHERE sha256 = ?", row["sha256"] as string);
      sql.exec(
        "UPDATE meta SET value = value - ? WHERE key = 'health_blob_bytes'",
        row["size"] as number,
      );
    }
  });
  const known = new Set(
    sql.exec("SELECT sha256 FROM health_blobs").map((row) => row["sha256"] as string),
  );
  const strays = (yield* files.list(prefix)).filter(
    (object) =>
      !known.has(object.key.slice(prefix.length)) && object.uploaded <= now - blobGracePeriodMs,
  );
  yield* files.delete(strays.map((object) => object.key));
  // With more due than one sweep deletes, the next runs a minute later.
  const sweptAt = due.length < blobSweepBatch ? now : now - blobSweepIntervalMs + 60_000;
  sql.exec(
    `INSERT INTO meta (key, value) VALUES ('health_blob_swept_at', ?)
     ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
    sweptAt,
  );
});
