import type { StoreSql } from "../store/StoreSql.ts";
import type { HealthBatch, RejectedLine } from "./HealthBatches.ts";

// Health batch status, kept in the user's store (store migration 4).

const select = `SELECT id, status, received_at AS receivedAt, finished_at AS finishedAt, lines,
  applied, rejected, rejected_lines AS rejectedLines, failure FROM health_batches WHERE id = ?`;

export const readHealthBatch = (sql: StoreSql, id: string): HealthBatch | null => {
  const row = sql.exec(select, id)[0];
  if (row === undefined) return null;
  const batch: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    if (value === null) continue;
    batch[key] =
      key === "rejectedLines" ? (JSON.parse(value as string) as Array<RejectedLine>) : value;
  }
  return batch as HealthBatch;
};

/** Records a batch as `queued` unless it's already known, and returns its status. */
export const receiveHealthBatch = (sql: StoreSql, id: string, at: number): HealthBatch => {
  sql.exec(
    "INSERT INTO health_batches (id, status, received_at) VALUES (?, 'queued', ?) ON CONFLICT (id) DO NOTHING",
    id,
    at,
  );
  const batch = readHealthBatch(sql, id);
  if (batch === null) throw new Error(`Health batch ${id} vanished`);
  return batch;
};

export const saveHealthBatch = (sql: StoreSql, batch: HealthBatch): void => {
  sql.exec(
    `INSERT INTO health_batches
      (id, status, received_at, finished_at, lines, applied, rejected, rejected_lines, failure)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET status = excluded.status, finished_at = excluded.finished_at,
        lines = excluded.lines, applied = excluded.applied, rejected = excluded.rejected,
        rejected_lines = excluded.rejected_lines, failure = excluded.failure`,
    batch.id,
    batch.status,
    batch.receivedAt,
    batch.finishedAt ?? null,
    batch.lines ?? null,
    batch.applied ?? null,
    batch.rejected ?? null,
    batch.rejectedLines === undefined ? null : JSON.stringify(batch.rejectedLines),
    batch.failure ?? null,
  );
};
