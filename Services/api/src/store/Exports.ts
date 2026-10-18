import { readHead, readMeta } from "./ChangeLog.ts";
import type { Snapshot } from "./Snapshots.ts";
import type { StoreSql } from "./StoreSql.ts";

// Data exports (851-2596, `docs/DECISIONS.md`): an export is built from a snapshot that covers
// everything stored when it was asked for. Asking makes the next snapshot due at once (still
// waiting out a bulk upload, `deferWhileIngesting`), and the export is ready once a snapshot
// covers it. The download streams that snapshot's parts, with the account's blobs and account
// data, so nothing is copied.

/** How often an account can ask for an export: asking again sooner gets the last one. */
export const exportInterval = 24 * 60 * 60 * 1000;

export interface ExportRequest {
  /** When it was asked for (Unix milliseconds): the export's ID. */
  readonly requestedAt: number;
  /** The store's `head` then: a snapshot at or after it holds everything the export needs. */
  readonly seq: number;
}

/** The latest export asked for, or `null`. */
export const readExportRequest = (sql: StoreSql): ExportRequest | null => {
  const requestedAt = readMeta(sql, "export_requested_at", -1);
  return requestedAt === -1 ? null : { requestedAt, seq: readMeta(sql, "export_seq", 0) };
};

/**
 * Asks for an export at `now`, unless one was asked for within `exportInterval`, and returns the
 * export asked for.
 */
export const requestExport = (sql: StoreSql, now: number): ExportRequest => {
  const last = readExportRequest(sql);
  if (last !== null && last.requestedAt > now - exportInterval) return last;
  const request = { requestedAt: now, seq: readHead(sql) };
  sql.transaction(() => {
    for (const [key, value] of [
      ["export_requested_at", request.requestedAt],
      ["export_seq", request.seq],
    ] as const) {
      sql.exec(
        `INSERT INTO meta (key, value) VALUES (?, ?)
          ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
        key,
        value,
      );
    }
  });
  return request;
};

/**
 * The `seq` a snapshot must reach for the export asked for, or `null` if it needs none: nothing
 * was stored when it was asked for, or the store was reset since (its `head` went back).
 */
const neededSeq = (sql: StoreSql, request: ExportRequest) => {
  const seq = Math.min(request.seq, readHead(sql));
  return seq === 0 ? null : seq;
};

/** When an export makes the next snapshot due, or `null` if none waits for one. */
export const exportSnapshotDueAt = (sql: StoreSql, covered: number): number | null => {
  const request = readExportRequest(sql);
  if (request === null) return null;
  const seq = neededSeq(sql, request);
  return seq !== null && seq > covered ? request.requestedAt : null;
};

/**
 * Whether the export asked for is ready, and the snapshot it's built from: the latest
 * (`latestSnapshot`), once it covers the export (`null` for a store that had nothing).
 */
export const exportSnapshot = (
  sql: StoreSql,
  request: ExportRequest,
  latest: Snapshot | null,
): { readonly ready: boolean; readonly snapshot: Snapshot | null } => {
  const seq = neededSeq(sql, request);
  if (seq === null) return { ready: true, snapshot: latest };
  return latest !== null && latest.seq >= seq
    ? { ready: true, snapshot: latest }
    : { ready: false, snapshot: null };
};
