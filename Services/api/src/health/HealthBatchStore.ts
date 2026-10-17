import type { StoreSql } from "../store/StoreSql.ts";
import { noteIngestion } from "../store/Snapshots.ts";
import type { HealthBatch, RejectedLine } from "./HealthBatches.ts";

// Health batch status, kept in the user's store (store migration 4).

/**
 * How long a batch may stay `queued` or `applying` before it's reported `failed`. Its last
 * delivery may have failed to record the failure (e.g. the store was down), so without this the
 * client would wait forever. A batch reported failed is never applied later.
 */
export const healthBatchTimeouts: Partial<Record<string, number>> = {
  queued: 24 * 60 * 60 * 1000,
  applying: 60 * 60 * 1000,
};

const select = `SELECT id, status, received_at AS receivedAt, finished_at AS finishedAt, lines,
  applied, rejected, rejected_lines AS rejectedLines, failure, updated_at AS updatedAt
  FROM health_batches WHERE id = ?`;

export const readHealthBatch = (sql: StoreSql, id: string, now: number): HealthBatch | null => {
  const row = sql.exec(select, id)[0];
  if (row === undefined) return null;
  const batch: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    if (value === null || key === "updatedAt") continue;
    batch[key] =
      key === "rejectedLines" ? (JSON.parse(value as string) as Array<RejectedLine>) : value;
  }
  const timeout = healthBatchTimeouts[row["status"] as string];
  if (timeout !== undefined && now - (row["updatedAt"] as number) > timeout) {
    return { ...(batch as HealthBatch), status: "failed", failure: "The batch timed out" };
  }
  return batch as HealthBatch;
};

/** Records a batch as `queued` unless it's already known, and returns its status. */
export const receiveHealthBatch = (sql: StoreSql, id: string, at: number): HealthBatch => {
  noteIngestion(sql, at);
  sql.exec(
    `INSERT INTO health_batches (id, status, received_at, updated_at) VALUES (?, 'queued', ?, ?)
      ON CONFLICT (id) DO NOTHING`,
    id,
    at,
    at,
  );
  const batch = readHealthBatch(sql, id, at);
  if (batch === null) throw new Error(`Health batch ${id} vanished`);
  return batch;
};

export const saveHealthBatch = (sql: StoreSql, batch: HealthBatch, at: number): void => {
  noteIngestion(sql, at);
  sql.exec(
    `INSERT INTO health_batches
      (id, status, received_at, finished_at, lines, applied, rejected, rejected_lines, failure,
        updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET status = excluded.status, finished_at = excluded.finished_at,
        lines = excluded.lines, applied = excluded.applied, rejected = excluded.rejected,
        rejected_lines = excluded.rejected_lines, failure = excluded.failure,
        updated_at = excluded.updated_at`,
    batch.id,
    batch.status,
    batch.receivedAt,
    batch.finishedAt ?? null,
    batch.lines ?? null,
    batch.applied ?? null,
    batch.rejected ?? null,
    batch.rejectedLines === undefined ? null : JSON.stringify(batch.rejectedLines),
    batch.failure ?? null,
    at,
  );
};
