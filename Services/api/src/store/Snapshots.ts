import { Effect } from "effect";
import { makeId } from "../core/Ids.ts";
import { readEpoch, readHead } from "./ChangeLog.ts";
import { type Entity, fromColumnValue } from "./Entities.ts";
import type { SqlRow, StoreSql } from "./StoreSql.ts";

// Snapshots of a store (`docs/SYNC.md`): every record as of a `seq`, in gzip NDJSON parts in R2,
// so a new device doesn't replay the whole change log. Written a part per alarm, so writes keep
// flowing and no invocation runs long. Every alarm also does the upkeep: compacting the change
// log behind the latest snapshot and deleting replaced snapshots.

export const snapshotPolicy = {
  /** Write a snapshot once this many changes have happened since the last one... */
  minChanges: 50_000,
  /** ...or this long after the last one (or the first change), if anything changed. */
  maxAge: 7 * 24 * 60 * 60 * 1000,
  /** Records per part, so a failed download only retries one part. */
  partRecords: 250_000,
  /** Rows read per query while writing a part. */
  pageRows: 5_000,
  /** Changes covered by the latest snapshot are deleted once they're this old. */
  changeRetention: 30 * 24 * 60 * 60 * 1000,
  /** A replaced snapshot stays downloadable this long, for clients midway through it. */
  replacedRetention: 7 * 24 * 60 * 60 * 1000,
};
export type SnapshotPolicy = typeof snapshotPolicy;

export interface SnapshotPart {
  /** The part's object key in the snapshot bucket. It includes the part's hash, so it's immutable. */
  readonly key: string;
  readonly records: number;
  readonly bytes: number;
  /** SHA-256 of the compressed part, hex. */
  readonly sha256: string;
}

export interface SnapshotEntity {
  readonly entity: string;
  readonly parts: ReadonlyArray<SnapshotPart>;
}

export interface Snapshot {
  readonly id: string;
  /** The store's `head` when the snapshot started; clients pull changes after it. */
  readonly seq: number;
  readonly epoch: number;
  readonly createdAt: number;
  readonly finishedAt: number | null;
  readonly replacedAt: number | null;
  readonly entities: ReadonlyArray<SnapshotEntity>;
}

/** Where snapshot parts are stored (R2 in the Worker). */
export interface SnapshotFiles {
  readonly put: (key: string, bytes: Uint8Array) => Effect.Effect<void>;
  readonly delete: (keys: ReadonlyArray<string>) => Effect.Effect<void>;
}

const toSnapshot = (row: SqlRow): Snapshot => ({
  id: row["id"] as string,
  seq: row["seq"] as number,
  epoch: row["epoch"] as number,
  createdAt: row["created_at"] as number,
  finishedAt: row["finished_at"] as number | null,
  replacedAt: row["replaced_at"] as number | null,
  entities: JSON.parse(row["entities"] as string) as Array<SnapshotEntity>,
});

const partKeys = (snapshot: Snapshot) =>
  snapshot.entities.flatMap((entity) => entity.parts.map((part) => part.key));

const readSnapshotRow = (sql: StoreSql, id: string): Snapshot | null => {
  const row = sql.exec("SELECT * FROM snapshots WHERE id = ?", id)[0];
  return row === undefined ? null : toSnapshot(row);
};

/**
 * A published snapshot of the current epoch by ID (replaced ones too, until they're deleted), or
 * `null`: unknown, still being written, from another epoch, or gone.
 */
export const readSnapshot = (sql: StoreSql, id: string): Snapshot | null => {
  const snapshot = readSnapshotRow(sql, id);
  if (snapshot === null || snapshot.finishedAt === null) return null;
  return snapshot.epoch === readEpoch(sql) ? snapshot : null;
};

const latestQuery = `SELECT * FROM snapshots
  WHERE finished_at IS NOT NULL AND replaced_at IS NULL AND epoch = ?
  ORDER BY finished_at DESC LIMIT 1`;

/** The latest published snapshot of the current epoch, or `null`. */
export const latestSnapshot = (sql: StoreSql): Snapshot | null => {
  const row = sql.exec(latestQuery, readEpoch(sql))[0];
  return row === undefined ? null : toSnapshot(row);
};

/** The latest snapshot's `seq` and start, without reading its parts. */
const latestSummary = (sql: StoreSql) => {
  const row = sql.exec(
    latestQuery.replace("SELECT *", "SELECT seq, created_at"),
    readEpoch(sql),
  )[0];
  return row === undefined
    ? null
    : { seq: row["seq"] as number, createdAt: row["created_at"] as number };
};

/** The oldest change still in the log. `seq` and `at` both increase, so it's the first. */
const firstChange = (sql: StoreSql) => {
  const row = sql.exec("SELECT seq, at FROM changes ORDER BY seq LIMIT 1")[0];
  return row === undefined ? null : { seq: row["seq"] as number, at: row["at"] as number };
};

/**
 * When the next snapshot is due: now, a time in the future, or `null` if nothing changed since
 * the last one.
 */
export const nextSnapshotAt = (sql: StoreSql, now: number, policy = snapshotPolicy) => {
  const head = readHead(sql);
  const latest = latestSummary(sql);
  const covered = latest?.seq ?? 0;
  if (head <= covered) return null;
  if (head - covered >= policy.minChanges) return now;
  const since = latest?.createdAt ?? firstChange(sql)?.at ?? now;
  return Math.max(now, since + policy.maxAge);
};

/** When upkeep is next due: compacting the log, or deleting a replaced snapshot. */
const nextUpkeepAt = (sql: StoreSql, policy: SnapshotPolicy) => {
  const times: Array<number> = [];
  const replaced = sql.exec("SELECT min(replaced_at) AS at FROM snapshots")[0]?.["at"];
  if (typeof replaced === "number") times.push(replaced + policy.replacedRetention);
  const latest = latestSummary(sql);
  const first = firstChange(sql);
  if (latest !== null && first !== null && first.seq <= latest.seq) {
    times.push(first.at + policy.changeRetention);
  }
  return times.length === 0 ? null : Math.min(...times);
};

interface Job {
  readonly snapshotId: string;
  /** Position in the snapshot's `entity_names`, fixed when it started. */
  readonly entityIndex: number;
  readonly afterId: string | null;
  readonly part: number;
}

const readJob = (sql: StoreSql): Job | null => {
  const row = sql.exec("SELECT * FROM snapshot_job WHERE id = 1")[0];
  if (row === undefined) return null;
  return {
    snapshotId: row["snapshot_id"] as string,
    entityIndex: row["entity_index"] as number,
    afterId: row["after_id"] as string | null,
    part: row["part"] as number,
  };
};

const saveJob = (sql: StoreSql, job: Job) =>
  sql.exec(
    `INSERT INTO snapshot_job (id, snapshot_id, entity_index, after_id, part) VALUES (1, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET snapshot_id = excluded.snapshot_id,
        entity_index = excluded.entity_index, after_id = excluded.after_id, part = excluded.part`,
    job.snapshotId,
    job.entityIndex,
    job.afterId,
    job.part,
  );

/** When the store's alarm should next go off for snapshot work and upkeep, or `null`. */
export const nextAlarmAt = (sql: StoreSql, now: number, policy = snapshotPolicy) => {
  if (readJob(sql) !== null) return now;
  const times = [nextSnapshotAt(sql, now, policy), nextUpkeepAt(sql, policy)].filter(
    (time): time is number => time !== null,
  );
  return times.length === 0 ? null : Math.min(...times);
};

/** Compresses NDJSON with gzip as it's written. `finish` returns the compressed bytes. */
const gzipWriter = () => {
  const stream = new CompressionStream("gzip");
  const writer = stream.writable.getWriter();
  const chunks: Array<Uint8Array> = [];
  const collected = (async () => {
    const reader = stream.readable.getReader();
    for (let read = await reader.read(); !read.done; read = await reader.read()) {
      chunks.push(read.value);
    }
  })();
  const encoder = new TextEncoder();
  return {
    write: (text: string) => Effect.promise(() => writer.write(encoder.encode(text))),
    finish: Effect.promise(async () => {
      await writer.close();
      await collected;
      const bytes = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      return bytes;
    }),
  };
};

const sha256Hex = (bytes: Uint8Array) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>)).pipe(
    Effect.map((digest) =>
      Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join(""),
    ),
  );

/**
 * Deletes the changes the latest snapshot covers once they're older than `changeRetention`, and
 * raises the horizon to the newest one deleted. Never deletes changes newer than the snapshot.
 */
export const compactChanges = (sql: StoreSql, now: number, policy = snapshotPolicy) => {
  const latest = latestSummary(sql);
  if (latest === null) return;
  // `seq` and `at` both increase, so the deletable changes are a prefix of the log.
  const newest = sql.exec(
    "SELECT max(seq) AS seq FROM changes WHERE seq <= ? AND at < ?",
    latest.seq,
    now - policy.changeRetention,
  )[0]?.["seq"];
  if (typeof newest !== "number") return;
  sql.transaction(() => {
    sql.exec("DELETE FROM changes WHERE seq <= ?", newest);
    sql.exec(
      "INSERT INTO meta (key, value) VALUES ('horizon', ?) ON CONFLICT (key) DO UPDATE SET value = max(value, excluded.value)",
      newest,
    );
  });
};

/** Deletes a snapshot's row and parts. */
const deleteSnapshot = Effect.fnUntraced(function* (
  sql: StoreSql,
  files: SnapshotFiles,
  snapshot: Snapshot,
) {
  yield* files.delete(partKeys(snapshot));
  sql.transaction(() => {
    sql.exec("DELETE FROM snapshot_job WHERE snapshot_id = ?", snapshot.id);
    sql.exec("DELETE FROM snapshots WHERE id = ?", snapshot.id);
  });
});

/**
 * Upkeep that's due by `now`: compacts the change log and deletes snapshots replaced more than
 * `replacedRetention` ago, with their parts.
 */
export const doUpkeep = Effect.fnUntraced(function* (
  sql: StoreSql,
  files: SnapshotFiles,
  now: number,
  policy: SnapshotPolicy = snapshotPolicy,
) {
  compactChanges(sql, now, policy);
  const replaced = sql
    .exec("SELECT * FROM snapshots WHERE replaced_at < ?", now - policy.replacedRetention)
    .map(toSnapshot);
  for (const snapshot of replaced) yield* deleteSnapshot(sql, files, snapshot);
});

/**
 * Does the next bit of snapshot work: starts a snapshot if one is due, writes one part, or
 * publishes a finished snapshot. Returns `continue` while there's more to do.
 */
export const writeSnapshotStep = Effect.fnUntraced(function* (
  sql: StoreSql,
  entities: ReadonlyArray<Entity>,
  files: SnapshotFiles,
  now: number,
  policy: SnapshotPolicy = snapshotPolicy,
) {
  let job = readJob(sql);
  if (job === null) {
    if (nextSnapshotAt(sql, now, policy) !== now) return "idle" as const;
    const snapshotId = yield* makeId("snp");
    sql.transaction(() => {
      sql.exec(
        `INSERT INTO snapshots (id, seq, epoch, created_at, entity_names, entities)
          VALUES (?, ?, ?, ?, ?, '[]')`,
        snapshotId,
        readHead(sql),
        readEpoch(sql),
        now,
        JSON.stringify(entities.map((entity) => entity.name)),
      );
      saveJob(sql, { snapshotId, entityIndex: 0, afterId: null, part: 0 });
    });
    job = readJob(sql);
    if (job === null) return yield* Effect.die("The snapshot job vanished");
  }
  const { snapshotId } = job;
  const snapshot = readSnapshotRow(sql, snapshotId);
  if (snapshot === null) return yield* Effect.die(`Snapshot ${snapshotId} vanished`);
  const names = JSON.parse(
    sql.exec("SELECT entity_names FROM snapshots WHERE id = ?", snapshotId)[0]?.[
      "entity_names"
    ] as string,
  ) as Array<string>;

  const name = names[job.entityIndex];
  if (name === undefined) {
    // Every entity is written: publish it.
    sql.transaction(() => {
      sql.exec(
        "UPDATE snapshots SET replaced_at = ? WHERE finished_at IS NOT NULL AND replaced_at IS NULL",
        now,
      );
      sql.exec("UPDATE snapshots SET finished_at = ? WHERE id = ?", now, snapshotId);
      sql.exec("DELETE FROM snapshot_job WHERE id = 1");
    });
    return "finished" as const;
  }
  const entity = entities.find((candidate) => candidate.name === name);
  if (entity === undefined) {
    // A deploy removed one of its entities midway; a new snapshot starts when it's next due.
    yield* deleteSnapshot(sql, files, snapshot);
    return "idle" as const;
  }

  // One part: rows after the cursor, by `id` (never by offset, so rows deleted meanwhile can't
  // make it skip any), a page at a time. Writes interleave between pages; replaying the changes
  // after the snapshot's `seq` fixes up anything newer.
  const columns = entity.fields.map(({ column }) => `"${column}"`);
  const page = `SELECT ${["id", ...columns].join(", ")} FROM "${entity.name}"
    WHERE id > ? ORDER BY id LIMIT ?`;
  const gzip = gzipWriter();
  let records = 0;
  let afterId = job.afterId ?? "";
  let exhausted = false;
  while (records < policy.partRecords) {
    const limit = Math.min(policy.pageRows, policy.partRecords - records);
    const rows = sql.exec(page, afterId, limit);
    let text = "";
    for (const row of rows) {
      const record: Record<string, unknown> = { id: row["id"] };
      for (const { field, column, type } of entity.fields) {
        record[field] = fromColumnValue(type, row[column]);
      }
      text += `${JSON.stringify(record)}\n`;
    }
    if (text !== "") yield* gzip.write(text);
    records += rows.length;
    afterId = (rows[rows.length - 1]?.["id"] as string | undefined) ?? afterId;
    if (rows.length < limit) {
      exhausted = true;
      break;
    }
  }
  const bytes = yield* gzip.finish;

  const parts: Array<SnapshotPart> = [];
  if (records > 0) {
    const sha256 = yield* sha256Hex(bytes);
    const key = `snapshots/${snapshotId}/${entity.name}/${job.part}-${sha256}.ndjson.gz`;
    yield* files.put(key, bytes);
    parts.push({ key, records, bytes: bytes.length, sha256 });
  }
  const discard = files.delete(parts.map((part) => part.key));
  // Requests run while the part uploads; if the store was deleted meanwhile, so is the part.
  if (readJob(sql)?.snapshotId !== snapshotId) {
    yield* discard;
    return "idle" as const;
  }
  const next: Job = exhausted
    ? { snapshotId, entityIndex: job.entityIndex + 1, afterId: null, part: 0 }
    : { snapshotId, entityIndex: job.entityIndex, afterId, part: job.part + 1 };
  yield* Effect.try(() =>
    sql.transaction(() => {
      const current = readSnapshotRow(sql, snapshotId);
      if (current === null) throw new Error(`Snapshot ${snapshotId} vanished`);
      const others = current.entities.filter((written) => written.entity !== entity.name);
      const written = current.entities.find((written) => written.entity === entity.name);
      sql.exec(
        "UPDATE snapshots SET entities = ? WHERE id = ?",
        JSON.stringify([
          ...others,
          { entity: entity.name, parts: [...(written?.parts ?? []), ...parts] },
        ]),
        snapshotId,
      );
      saveJob(sql, next);
    }),
  ).pipe(
    Effect.tapError(() => discard),
    Effect.orDie,
  );
  return "continue" as const;
});

/** Every part key of every snapshot, for deleting a store. */
export const allSnapshotKeys = (sql: StoreSql) =>
  sql.exec("SELECT * FROM snapshots").map(toSnapshot).flatMap(partKeys);
