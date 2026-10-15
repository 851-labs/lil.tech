import { Clock, Context, Effect, Option, Result, Schema } from "effect";
import type { DeviceId, UserId } from "../core/Ids.ts";
import { Mutation } from "../store/Changes.ts";
import { stampDevice } from "../store/Entities.ts";
import { UserStores } from "../store/UserStores.ts";
import type { HealthBatch, RejectedLine } from "./HealthBatches.ts";
import { healthEntities } from "./HealthEntities.ts";

// Health ingestion (`docs/SYNC.md`): the iPhone uploads gzip NDJSON batch files, one mutation per
// line, which the API stores in R2 and queues. The queue consumer applies them to the user's store.

/** What the queue carries for an uploaded batch. */
export interface HealthBatchMessage {
  readonly userId: UserId;
  readonly batchId: string;
  /**
   * The uploading device, which device-scoped records are stamped with. Missing from messages
   * queued before it was added; their device-scoped lines are rejected.
   */
  readonly deviceId?: DeviceId;
}

/** Where an uploaded batch file is kept until it's applied. */
export const healthBatchKey = (userId: UserId, batchId: string) =>
  `${healthBatchPrefix(userId)}${batchId}.ndjson.gz`;

/** Where a user's batch files are. */
export const healthBatchPrefix = (userId: UserId) => `health-batches/${userId}/`;

/** Uploaded batch files (R2 in the Worker). */
export class HealthBatchFiles extends Context.Service<
  HealthBatchFiles,
  {
    readonly put: (key: string, bytes: Uint8Array) => Effect.Effect<void>;
    /** The file's bytes as a stream, so a batch never has to fit in memory whole. */
    readonly open: (key: string) => Effect.Effect<Option.Option<ReadableStream<Uint8Array>>>;
    readonly delete: (key: string) => Effect.Effect<void>;
    /** Deletes every file whose key starts with `prefix`, e.g. a deleted user's. */
    readonly deletePrefix: (prefix: string) => Effect.Effect<void, BatchFilesUnavailable>;
  }
>()("lil/api/health/HealthBatchFiles") {}

/** R2 couldn't be reached; retrying can work. */
export class BatchFilesUnavailable extends Schema.TaggedError<BatchFilesUnavailable>()(
  "BatchFilesUnavailable",
  { message: Schema.String },
) {}

/** The queue of uploaded batches (a Cloudflare Queue in the Worker). */
export class HealthBatchQueue extends Context.Service<
  HealthBatchQueue,
  { readonly send: (message: HealthBatchMessage) => Effect.Effect<void> }
>()("lil/api/health/HealthBatchQueue") {}

/** Mutations applied per store call. Each call is one transaction in the store. */
export const healthChunkSize = 500;
/** The most a batch may decompress to. Lines are read as a stream, so this bounds work, not memory. */
export const maxDecompressedBatchBytes = 64 * 1024 * 1024;
const maxRejectedLines = 100;

const healthEntitiesByName = new Map(healthEntities.map((entity) => [entity.name, entity]));
const decodeMutation = Schema.decodeUnknownResult(Schema.fromJsonString(Mutation));

/** A line that passed validation, with its 1-based line number. */
interface ParsedLine {
  readonly line: number;
  readonly mutation: Mutation;
}

class BatchUnreadable extends Schema.TaggedError<BatchUnreadable>()("BatchUnreadable", {
  message: Schema.String,
}) {}

/**
 * Checks one line: valid JSON, a mutation of a health entity, an ID in the entity's form, and for
 * an upsert a full row (ingestion sends whole records). Checking here means the store rarely
 * rejects a chunk.
 */
const parseLine = (
  content: string,
  deviceId: DeviceId | undefined,
  now: number,
): Result.Result<Mutation, string> => {
  const decoded = decodeMutation(content);
  if (Result.isFailure(decoded)) return Result.fail(decoded.failure.message);
  let mutation = decoded.success;
  const entity = healthEntitiesByName.get(mutation.entity);
  if (entity === undefined) return Result.fail(`Not a health entity: ${mutation.entity}`);
  if (entity.deviceScoped !== undefined) {
    if (deviceId === undefined) return Result.fail(`${entity.name} needs the uploading device`);
    if (!entity.deviceScoped.id.test(mutation.id)) {
      return Result.fail(`Invalid ${entity.name} ID ${mutation.id}`);
    }
    const id = stampDevice(deviceId, mutation.id);
    const { stampedAt } = entity.deviceScoped;
    mutation =
      mutation.op === "upsert"
        ? {
            ...mutation,
            id,
            row: {
              ...mutation.row,
              device: deviceId,
              ...(stampedAt === undefined ? {} : { [stampedAt]: now }),
            },
          }
        : { ...mutation, id };
  }
  if (!entity.isValidId(mutation.id))
    return Result.fail(`Invalid ${entity.name} ID ${mutation.id}`);
  if (mutation.op === "upsert") {
    const fields = entity.decodeFields(mutation.row);
    if (Result.isFailure(fields)) return Result.fail(fields.failure.message);
    const missing = entity.fields.find(
      ({ field, type }) => !type.nullable && fields.success[field] === undefined,
    );
    if (missing !== undefined) return Result.fail(`Missing ${missing.field}`);
  }
  return Result.succeed(mutation);
};

/** The longest line accepted. A health record is a few hundred bytes. */
export const maxBatchLineLength = 1024 * 1024;

/**
 * Reads a gzip NDJSON stream line by line, calling `onLine` with each non-empty line (or
 * `undefined` for one longer than `maxBatchLineLength`, which isn't kept) and its 1-based number.
 * Only the current line is buffered. Fails if the stream isn't gzip or decompresses to more than
 * `maxDecompressedBatchBytes`.
 */
const forEachLine = Effect.fnUntraced(function* <E, R>(
  stream: ReadableStream<Uint8Array>,
  onLine: (content: string | undefined, line: number) => Effect.Effect<void, E, R>,
) {
  const reader = stream
    .pipeThrough(new DecompressionStream("gzip"))
    .pipeThrough(new TextDecoderStream())
    .getReader();
  let pending = "";
  let tooLong = false;
  let line = 0;
  let size = 0;
  const lineEnded = (rest: string) => {
    line += 1;
    const content = tooLong ? undefined : pending + rest;
    pending = "";
    tooLong = false;
    return content === undefined || content.trim() !== "" ? onLine(content, line) : Effect.void;
  };
  while (true) {
    const read = yield* Effect.tryPromise({
      try: () => reader.read(),
      catch: (error) => new BatchUnreadable({ message: `Not a gzip file: ${String(error)}` }),
    });
    if (read.done) {
      if (pending !== "" || tooLong) yield* lineEnded("");
      return;
    }
    const text = read.value;
    size += text.length;
    if (size > maxDecompressedBatchBytes) {
      yield* Effect.promise(() => reader.cancel());
      return yield* new BatchUnreadable({ message: "The batch is too large when decompressed" });
    }
    let start = 0;
    for (let newline = text.indexOf("\n"); newline !== -1; newline = text.indexOf("\n", start)) {
      yield* lineEnded(tooLong ? "" : text.slice(start, newline));
      start = newline + 1;
    }
    if (!tooLong) {
      pending += text.slice(start);
      if (pending.length > maxBatchLineLength) {
        pending = "";
        tooLong = true;
      }
    }
  }
});

/**
 * Applies an uploaded batch to the user's store and records the outcome. Safe to run again for
 * the same batch (queues deliver at least once): a finished batch is skipped, and re-applying
 * rows changes nothing. Fails only when retrying could help, e.g. the store is unavailable.
 *
 * The file is streamed and applied a chunk at a time, so a file that turns out to be corrupt
 * partway can be partly applied before the batch fails.
 */
const applyHealthBatch = Effect.fnUntraced(function* (message: HealthBatchMessage) {
  const files = yield* HealthBatchFiles;
  const store = (yield* UserStores).forUser(message.userId);
  const key = healthBatchKey(message.userId, message.batchId);

  const known = yield* store.healthBatch(message.batchId);
  if (known?.status === "applied" || known?.status === "failed") return;
  const receivedAt = known?.receivedAt ?? (yield* Clock.currentTimeMillis);
  const finish = (batch: Omit<HealthBatch, "id" | "receivedAt" | "finishedAt">) =>
    Effect.gen(function* () {
      const finishedAt = yield* Clock.currentTimeMillis;
      yield* store.saveHealthBatch({ ...batch, id: message.batchId, receivedAt, finishedAt });
      yield* files.delete(key);
    });

  yield* store.saveHealthBatch({ id: message.batchId, status: "applying", receivedAt });
  const stream = yield* files.open(key);
  if (Option.isNone(stream)) {
    return yield* finish({ status: "failed", failure: "The batch file is missing" });
  }

  let lines = 0;
  let applied = 0;
  const rejected: Array<RejectedLine> = [];
  const chunk: Array<ParsedLine> = [];
  // If the store rejects a mutation anyway (e.g. a field it validates differently), that line is
  // rejected and the rest of the chunk is tried again.
  const applyChunk = Effect.gen(function* () {
    while (chunk.length > 0) {
      const result = yield* store
        .applyMutations(chunk.map(({ mutation }) => mutation))
        .pipe(Effect.result);
      if (Result.isSuccess(result)) {
        applied += chunk.length;
        chunk.length = 0;
        return;
      }
      const error = result.failure;
      if (error._tag !== "InvalidMutation") return yield* error;
      const [invalid] = chunk.splice(error.index, 1);
      if (invalid !== undefined) rejected.push({ line: invalid.line, message: error.message });
    }
  });

  const read = yield* forEachLine(stream.value, (content, line) =>
    Effect.gen(function* () {
      lines += 1;
      if (content === undefined) {
        rejected.push({ line, message: `Longer than ${maxBatchLineLength} characters` });
        return;
      }
      const parsed = parseLine(content, message.deviceId, yield* Clock.currentTimeMillis);
      if (Result.isFailure(parsed)) {
        rejected.push({ line, message: parsed.failure });
        return;
      }
      chunk.push({ line, mutation: parsed.success });
      if (chunk.length >= healthChunkSize) yield* applyChunk;
    }),
  ).pipe(Effect.andThen(applyChunk), Effect.result);
  if (Result.isFailure(read)) {
    if (read.failure._tag !== "BatchUnreadable") return yield* read.failure;
    return yield* finish({ status: "failed", failure: read.failure.message });
  }

  rejected.sort((a, b) => a.line - b.line);
  yield* finish({
    status: "applied",
    lines,
    applied,
    rejected: rejected.length,
    rejectedLines: rejected.slice(0, maxRejectedLines),
  });
});

const dropBatchFile = Effect.fnUntraced(function* (message: HealthBatchMessage) {
  yield* (yield* HealthBatchFiles).delete(healthBatchKey(message.userId, message.batchId));
});

/**
 * Applies an uploaded batch to the user's store and records the outcome (`applyHealthBatch`). A
 * batch for an account deleted since it was queued is dropped with its file.
 */
export const ingestHealthBatch = Effect.fn("ingestHealthBatch")(function* (
  message: HealthBatchMessage,
) {
  yield* applyHealthBatch(message).pipe(
    Effect.catchTag("AccountDeleted", () => dropBatchFile(message)),
  );
});

/**
 * Marks a batch failed after its last delivery attempt, so its status doesn't stay `applying`.
 * The message then goes to the dead-letter queue.
 */
export const failHealthBatch = Effect.fn("failHealthBatch")(function* (
  message: HealthBatchMessage,
  failure: string,
) {
  yield* recordFailure(message, failure).pipe(
    // A deleted account keeps nothing, not even the batch's status.
    Effect.catchTag("AccountDeleted", () => dropBatchFile(message)),
  );
});

const recordFailure = Effect.fnUntraced(function* (message: HealthBatchMessage, failure: string) {
  const store = (yield* UserStores).forUser(message.userId);
  const known = yield* store.healthBatch(message.batchId);
  // A delivery that overlapped may have finished it.
  if (known?.status === "applied" || known?.status === "failed") return;
  const now = yield* Clock.currentTimeMillis;
  yield* (yield* HealthBatchFiles).delete(healthBatchKey(message.userId, message.batchId));
  yield* store.saveHealthBatch({
    id: message.batchId,
    status: "failed",
    receivedAt: known?.receivedAt ?? now,
    finishedAt: now,
    failure,
  });
});
