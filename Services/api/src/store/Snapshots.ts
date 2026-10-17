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
  /**
   * A snapshot is due once this share of the latest snapshot's records have changed since it,
   * and at least `minChanges`. Rewriting a store of millions for a few thousand changes isn't
   * worth it: a new device pulls those from the log.
   */
  changeShare: 0.25,
  /** ...and at least this many changes... */
  minChanges: 50_000,
  /** ...or this long after the last one (or the first change), if anything changed. */
  maxAge: 7 * 24 * 60 * 60 * 1000,
  /**
   * A due snapshot waits until no changes have arrived for this long: during a bulk upload the
   * store would otherwise rewrite everything stored so far, again and again, while the uploads
   * and their applies wait their turn.
   */
  quietPeriod: 2 * 60 * 1000,
  /** ...but no longer than this after it became due, so a store that never goes quiet still gets one. */
  maxDeferral: 60 * 60 * 1000,
  /**
   * Records per part, so a failed download only retries one part. Each alarm writes one part,
   * and a store can do nothing else meanwhile, so it's small: about a second's work.
   */
  partRecords: 25_000,
  /** ...and at most this many bytes of rows before compression, for entities with big rows. */
  partBytes: 8 * 1024 * 1024,
  /** Rows read per query while writing a part. */
  pageRows: 5_000,
  /** Changes covered by the latest snapshot are deleted once they're this old. */
  changeRetention: 30 * 24 * 60 * 60 * 1000,
  /** Changes deleted per alarm at most; the rest go in the alarms after. */
  compactionChunk: 50_000,
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

/** The latest snapshot's `seq`, start and finish, without reading its parts. */
const latestSummary = (sql: StoreSql) => {
  const row = sql.exec(
    latestQuery.replace("SELECT *", "SELECT seq, created_at, finished_at"),
    readEpoch(sql),
  )[0];
  return row === undefined
    ? null
    : {
        seq: row["seq"] as number,
        createdAt: row["created_at"] as number,
        finishedAt: row["finished_at"] as number,
      };
};

/** How many records the latest snapshot holds, from its manifest. */
const latestRecords = (sql: StoreSql) => {
  const row = sql.exec(latestQuery.replace("SELECT *", "SELECT entities"), readEpoch(sql))[0];
  if (row === undefined) return 0;
  const entities = JSON.parse(row["entities"] as string) as Array<SnapshotEntity>;
  return entities.reduce(
    (total, entity) => total + entity.parts.reduce((sum, part) => sum + part.records, 0),
    0,
  );
};

/**
 * Notes that the store is ingesting (a batch received or applied), so snapshots wait: uploads
 * that change nothing (a batch sent again) are work the snapshot would compete with too.
 */
export const noteIngestion = (sql: StoreSql, at: number) =>
  sql.exec(
    `INSERT INTO meta (key, value) VALUES ('ingested_at', ?)
      ON CONFLICT (key) DO UPDATE SET value = max(value, excluded.value)`,
    at,
  );

/** When the store last took in anything: a change, or a batch received or applied. */
const lastActivityAt = (sql: StoreSql) => {
  const change = sql.exec("SELECT at FROM changes ORDER BY seq DESC LIMIT 1")[0]?.["at"];
  const ingested = sql.exec("SELECT value FROM meta WHERE key = 'ingested_at'")[0]?.["value"];
  const times = [change, ingested].filter((at): at is number => typeof at === "number");
  return times.length === 0 ? null : Math.max(...times);
};

/** The oldest change still in the log. `seq` and `at` both increase, so it's the first. */
const firstChange = (sql: StoreSql) => {
  const row = sql.exec("SELECT seq, at FROM changes ORDER BY seq LIMIT 1")[0];
  return row === undefined ? null : { seq: row["seq"] as number, at: row["at"] as number };
};

/** When change `seq` (or the first after it still in the log) arrived. */
const changeAt = (sql: StoreSql, seq: number) => {
  const at = sql.exec("SELECT at FROM changes WHERE seq >= ? ORDER BY seq LIMIT 1", seq)[0]?.["at"];
  return typeof at === "number" ? at : null;
};

/**
 * Not before the store has been quiet for `quietPeriod`, but no later than `maxDeferral` after
 * `due`.
 */
const deferWhileIngesting = (sql: StoreSql, due: number, now: number, policy: SnapshotPolicy) => {
  const last = lastActivityAt(sql);
  const quiet = last === null ? due : last + policy.quietPeriod;
  return Math.max(now, due, Math.min(quiet, due + policy.maxDeferral));
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
  const since = latest?.createdAt ?? firstChange(sql)?.at ?? now;
  const enough = Math.max(
    policy.minChanges,
    Math.ceil((latest === null ? 0 : latestRecords(sql)) * policy.changeShare),
  );
  // Due when enough had changed (when the change that made it enough arrived), or at `maxAge`,
  // but not before the latest finished: a long snapshot mustn't make the next one start at once.
  const enoughAt = head - covered >= enough ? (changeAt(sql, covered + enough) ?? since) : null;
  const due = Math.max(
    Math.min(enoughAt ?? Infinity, since + policy.maxAge),
    latest?.finishedAt ?? 0,
  );
  return deferWhileIngesting(sql, due, now, policy);
};

/**
 * When snapshot work is next due: continuing the one in progress, which pauses while the store
 * ingests but for no longer than `maxDeferral` after it started, or starting the next one.
 */
const nextSnapshotWorkAt = (sql: StoreSql, now: number, policy: SnapshotPolicy) => {
  const job = readJob(sql);
  if (job === null) return nextSnapshotAt(sql, now, policy);
  const started = readSnapshotRow(sql, job.snapshotId)?.createdAt ?? now;
  return deferWhileIngesting(sql, started, now, policy);
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
  const times = [nextSnapshotWorkAt(sql, now, policy), nextUpkeepAt(sql, policy)].filter(
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
 * Deletes the oldest changes the latest snapshot covers once they're older than
 * `changeRetention`, at most `compactionChunk` per call (the alarm calls again while more are
 * due), and raises the horizon to the newest one deleted. Never deletes changes newer than the
 * snapshot. Only reads the oldest change and the chunk, so it's cheap when there's nothing to do.
 */
export const compactChanges = (sql: StoreSql, now: number, policy = snapshotPolicy) => {
  const latest = latestSummary(sql);
  const first = firstChange(sql);
  if (latest === null || first === null) return;
  // `seq` and `at` both increase, so the deletable changes are a prefix of the log.
  const cutoff = now - policy.changeRetention;
  if (first.seq > latest.seq || first.at >= cutoff) return;
  const upTo = sql.exec(
    `SELECT max(seq) AS seq FROM (
      SELECT seq FROM changes WHERE seq <= ? AND at < ? ORDER BY seq LIMIT ?)`,
    latest.seq,
    cutoff,
    policy.compactionChunk,
  )[0]?.["seq"];
  if (typeof upTo !== "number") return;
  sql.transaction(() => {
    sql.exec("DELETE FROM changes WHERE seq <= ?", upTo);
    sql.exec(
      "INSERT INTO meta (key, value) VALUES ('horizon', ?) ON CONFLICT (key) DO UPDATE SET value = max(value, excluded.value)",
      upTo,
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
  // Not yet, even when the alarm went off for other upkeep.
  if (nextSnapshotWorkAt(sql, now, policy) !== now) return "idle" as const;
  let job = readJob(sql);
  if (job === null) {
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
  let textBytes = 0;
  let afterId = job.afterId ?? "";
  let exhausted = false;
  while (records < policy.partRecords && textBytes < policy.partBytes) {
    if (records > 0) {
      // Lets the store's other calls in between pages (uploads, ingestion): reading and
      // compressing alone never give up the event loop.
      yield* Effect.yieldNow;
      // The store was deleted meanwhile: nothing of it goes to R2.
      if (readJob(sql)?.snapshotId !== snapshotId) {
        yield* gzip.finish;
        return "idle" as const;
      }
    }
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
    textBytes += text.length;
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
