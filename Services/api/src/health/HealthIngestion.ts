import { Clock, Context, Effect, Fiber, Option, Result, Schema } from "effect";
import type { DeviceId, UserId } from "../core/Ids.ts";
import { Mutation } from "../store/Changes.ts";
import { stampDevice } from "../store/Entities.ts";
import { deviceSignedOut } from "../store/RetiredDevices.ts";
import { Users } from "../core/Users.ts";
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

/**
 * The most mutations applied per store call. Each call is one transaction in the store, and
 * each costs a round trip, so big batches are applied in few of them (`docs/SYNC.md`).
 */
export const healthChunkSize = 5_000;
/**
 * The most line text per store call, in characters, so a call stays well under the RPC message
 * limit (32 MiB) even if every character takes 4 bytes. A batch holds two calls' worth at once
 * (one applying, the next read), and up to 4 batches apply at once in one isolate (128 MB).
 */
export const healthChunkBytes = 2 * 1024 * 1024;
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
  deviceRetired: boolean,
): Result.Result<Mutation, string> => {
  const decoded = decodeMutation(content);
  if (Result.isFailure(decoded)) return Result.fail(decoded.failure.message);
  let mutation = decoded.success;
  const entity = healthEntitiesByName.get(mutation.entity);
  if (entity === undefined) return Result.fail(`Not a health entity: ${mutation.entity}`);
  if (entity.deviceScoped !== undefined) {
    if (deviceId === undefined) return Result.fail(`${entity.name} needs the uploading device`);
    // Its records were deleted when it signed out (`docs/SYNC.md`), and mustn't come back.
    if (deviceRetired) return Result.fail(deviceSignedOut);
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

/** A batch's failure when its store reached the hard limit after `applied` lines. */
export const storageFullFailure = (applied: number) =>
  `The storage quota is full; ${applied} lines were applied before it`;

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
 * partway can be partly applied before the batch fails. The next chunk is read while one is
 * being applied, and chunks are applied in order. Returns the storage the account takes
 * afterwards, unless the batch was finished already.
 */
const applyHealthBatch = Effect.fnUntraced(function* (message: HealthBatchMessage) {
  const files = yield* HealthBatchFiles;
  const store = (yield* UserStores).forUser(message.userId);
  const key = healthBatchKey(message.userId, message.batchId);

  // Checked once for the batch: all its device-scoped lines are from the same device.
  const {
    batch: begun,
    deviceRetired: retiredAtStart,
    busy,
  } = yield* store.beginHealthBatch(message.batchId, message.deviceId);
  if (busy) return "busy" as const;
  if (begun === null || begun.status !== "applying") return undefined;
  let deviceRetired = retiredAtStart;
  const { receivedAt } = begun;
  const startedAt = yield* Clock.currentTimeMillis;
  const finish = (batch: Omit<HealthBatch, "id" | "receivedAt" | "finishedAt">) =>
    Effect.gen(function* () {
      const finishedAt = yield* Clock.currentTimeMillis;
      const bytes = yield* store.finishHealthBatch({
        ...batch,
        id: message.batchId,
        receivedAt,
        finishedAt,
      });
      yield* files.delete(key);
      // The apply rate, in the message itself: Workers Logs keeps only the text. The wait since
      // the upload includes any earlier attempts.
      if (batch.status === "applied") {
        const applied = batch.applied ?? 0;
        const applyMs = finishedAt - startedAt;
        const rate = Math.round(applied / (Math.max(applyMs, 1) / 1000));
        yield* Effect.logInfo(
          `Health batch applied: ${applied} of ${batch.lines ?? 0} lines in ${applyMs} ms, ` +
            `${rate} items/s, ${startedAt - receivedAt} ms after it was received`,
        );
      }
      return bytes;
    });

  const stream = yield* files.open(key);
  if (Option.isNone(stream)) {
    return yield* finish({ status: "failed", failure: "The batch file is missing" });
  }

  let lines = 0;
  let applied = 0;
  const rejected: Array<RejectedLine> = [];
  let chunk: Array<ParsedLine> = [];
  let chunkBytes = 0;
  // If the store rejects a mutation anyway (e.g. a field it validates differently), that line is
  // rejected and the rest of the chunk is tried again.
  const applyChunk = Effect.fnUntraced(function* (chunk: Array<ParsedLine>) {
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
      // The device signed out while the batch was being applied: all its records are refused
      // at once, rather than one store call each.
      if (error.message === deviceSignedOut) {
        deviceRetired = true;
        const kept = chunk.filter(({ line, mutation }) => {
          const refused =
            mutation.op === "upsert" &&
            healthEntitiesByName.get(mutation.entity)?.deviceScoped !== undefined;
          if (refused) rejected.push({ line, message: error.message });
          return !refused;
        });
        chunk.splice(0, chunk.length, ...kept);
        continue;
      }
      const [invalid] = chunk.splice(error.index, 1);
      if (invalid !== undefined) rejected.push({ line: invalid.line, message: error.message });
    }
  });
  // The chunk being applied while the next one is read: at most one, so they apply in order.
  let applying: Fiber.Fiber<void, Effect.Error<ReturnType<typeof applyChunk>>> | undefined;
  const settle = Effect.suspend(() => {
    const fiber = applying;
    applying = undefined;
    return fiber === undefined ? Effect.void : Fiber.join(fiber);
  });
  const nextChunk = () => {
    const full = chunk;
    chunk = [];
    chunkBytes = 0;
    return full;
  };

  const read = yield* forEachLine(stream.value, (content, line) =>
    Effect.gen(function* () {
      lines += 1;
      if (content === undefined) {
        rejected.push({ line, message: `Longer than ${maxBatchLineLength} characters` });
        return;
      }
      const parsed = parseLine(
        content,
        message.deviceId,
        yield* Clock.currentTimeMillis,
        deviceRetired,
      );
      if (Result.isFailure(parsed)) {
        rejected.push({ line, message: parsed.failure });
        return;
      }
      chunk.push({ line, mutation: parsed.success });
      chunkBytes += content.length;
      if (chunk.length >= healthChunkSize || chunkBytes >= healthChunkBytes) {
        yield* settle;
        applying = yield* Effect.forkChild(applyChunk(nextChunk()));
      }
    }),
  ).pipe(
    Effect.andThen(settle),
    Effect.andThen(Effect.suspend(() => applyChunk(nextChunk()))),
    // A chunk still being applied finishes first; if it fails, that's the batch's failure.
    Effect.catch((error) => settle.pipe(Effect.andThen(Effect.fail(error)))),
    Effect.result,
  );
  if (Result.isFailure(read)) {
    switch (read.failure._tag) {
      case "BatchUnreadable":
        return yield* finish({ status: "failed", failure: read.failure.message });
      // Retrying won't make room. Chunks applied before it stay applied.
      case "StorageFull":
        return yield* finish({ status: "failed", failure: storageFullFailure(applied) });
      default:
        return yield* read.failure;
    }
  }

  rejected.sort((a, b) => a.line - b.line);
  return yield* finish({
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
 * Whether the core database knows the batch's user. A batch for one it doesn't (one queued before
 * the databases were wiped, 851-2686) must not reach a store: touching it would create a store
 * for nobody. If D1 can't answer, the user counts as known, so a D1 outage doesn't hold up
 * ingestion; a known user's batch is the normal case.
 */
const knowsUser = (message: HealthBatchMessage) =>
  Effect.gen(function* () {
    const user = yield* (yield* Users).findById(message.userId);
    if (Option.isSome(user)) return true;
    yield* Effect.logWarning(
      `Dropping batch ${message.batchId} for unknown user ${message.userId}`,
    );
    return false;
  }).pipe(
    Effect.catchTag("SqlError", (error) =>
      Effect.logWarning("Looking up a batch's user failed", error).pipe(Effect.as(true)),
    ),
  );

/**
 * Applies an uploaded batch to the user's store and records the outcome (`applyHealthBatch`). A
 * batch for an account deleted since it was queued, or for a user the core database doesn't know
 * (`knowsUser`), is dropped with its file. Returns `"busy"`, without applying anything, when the
 * store already applies as many batches as it takes at once (`healthBatchesAtOnce`).
 */
export const ingestHealthBatch = Effect.fn("ingestHealthBatch")(function* (
  message: HealthBatchMessage,
) {
  if (!(yield* knowsUser(message))) return yield* dropBatchFile(message);
  const store = (yield* UserStores).forUser(message.userId);
  const result = yield* applyHealthBatch(message).pipe(
    Effect.catchTag("AccountDeleted", () => dropBatchFile(message).pipe(Effect.as(undefined))),
    // A batch that failed partway frees its place among those its store applies at once.
    Effect.onError(() => store.releaseHealthBatch(message.batchId).pipe(Effect.ignore)),
  );
  // The store is busy with other batches: the caller puts it back in the queue (851-2652).
  if (result === "busy") return "busy" as const;
  if (result !== undefined) yield* recordStorage(message.userId, result);
});

/**
 * Records the store's size in D1 for finding the largest users, after a batch made it grow. It's
 * best-effort: nothing fails the batch.
 */
const recordStorage = (userId: UserId, bytes: number) =>
  Effect.gen(function* () {
    const measuredAt = yield* Clock.currentTimeMillis;
    yield* (yield* Users).recordStorage(userId, bytes, measuredAt);
  }).pipe(Effect.ignoreCause({ log: "Warn", message: "Recording the store's size failed" }));

/**
 * Marks a batch failed after its last delivery attempt, so its status doesn't stay `applying`.
 * The message then goes to the dead-letter queue.
 */
export const failHealthBatch = Effect.fn("failHealthBatch")(function* (
  message: HealthBatchMessage,
  failure: string,
) {
  if (!(yield* knowsUser(message))) return yield* dropBatchFile(message);
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
