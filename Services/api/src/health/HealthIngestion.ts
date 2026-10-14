import { Clock, Context, Effect, Option, Result, Schema } from "effect";
import type { UserId } from "../core/Ids.ts";
import { Mutation } from "../store/Changes.ts";
import { UserStores } from "../store/UserStores.ts";
import { type HealthBatch, maxHealthBatchBytes, type RejectedLine } from "./HealthBatches.ts";
import { healthEntities } from "./HealthEntities.ts";

// Health ingestion (`docs/SYNC.md`): the iPhone uploads gzip NDJSON batch files, one mutation per
// line, which the API stores in R2 and queues. The queue consumer applies them to the user's store.

/** What the queue carries for an uploaded batch. */
export interface HealthBatchMessage {
  readonly userId: UserId;
  readonly batchId: string;
}

/** Where an uploaded batch file is kept until it's applied. */
export const healthBatchKey = (userId: UserId, batchId: string) =>
  `health-batches/${userId}/${batchId}.ndjson.gz`;

/** Uploaded batch files (R2 in the Worker). */
export class HealthBatchFiles extends Context.Service<
  HealthBatchFiles,
  {
    readonly put: (key: string, bytes: Uint8Array) => Effect.Effect<void>;
    readonly get: (key: string) => Effect.Effect<Option.Option<Uint8Array>>;
    readonly delete: (key: string) => Effect.Effect<void>;
  }
>()("lil/api/health/HealthBatchFiles") {}

/** The queue of uploaded batches (a Cloudflare Queue in the Worker). */
export class HealthBatchQueue extends Context.Service<
  HealthBatchQueue,
  { readonly send: (message: HealthBatchMessage) => Effect.Effect<void> }
>()("lil/api/health/HealthBatchQueue") {}

/** Mutations applied per store call. Each call is one transaction in the store. */
export const healthChunkSize = 500;
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

const gunzip = (bytes: Uint8Array) =>
  Effect.tryPromise({
    try: () =>
      new Response(
        new Blob([bytes as Uint8Array<ArrayBuffer>])
          .stream()
          .pipeThrough(new DecompressionStream("gzip")),
      ).text(),
    catch: (error) => new BatchUnreadable({ message: `Not a gzip file: ${String(error)}` }),
  });

/**
 * Splits a batch file into valid mutations of health entities and rejected lines. Rows are
 * checked against their entity here, so the store rarely rejects a chunk.
 */
export const parseHealthBatch = Effect.fnUntraced(function* (bytes: Uint8Array) {
  const text = yield* gunzip(bytes);
  const parsed: Array<ParsedLine> = [];
  const rejected: Array<RejectedLine> = [];
  let lines = 0;
  for (const [index, content] of text.split("\n").entries()) {
    if (content.trim() === "") continue;
    lines += 1;
    const line = index + 1;
    const decoded = decodeMutation(content);
    if (Result.isFailure(decoded)) {
      rejected.push({ line, message: decoded.failure.message });
      continue;
    }
    const mutation = decoded.success;
    const entity = healthEntitiesByName.get(mutation.entity);
    if (entity === undefined) {
      rejected.push({ line, message: `Not a health entity: ${mutation.entity}` });
    } else if (!entity.isValidId(mutation.id)) {
      rejected.push({ line, message: `Invalid ${entity.name} ID ${mutation.id}` });
    } else {
      const fields = mutation.op === "upsert" ? entity.decodeFields(mutation.row) : undefined;
      if (fields !== undefined && Result.isFailure(fields)) {
        rejected.push({ line, message: fields.failure.message });
      } else {
        parsed.push({ line, mutation });
      }
    }
  }
  return { lines, parsed, rejected };
});

/**
 * Applies an uploaded batch to the user's store and records the outcome. Safe to run again for
 * the same batch (queues deliver at least once): an applied batch is skipped, and re-applying
 * rows changes nothing. Fails only when retrying could help, e.g. the store is unavailable.
 */
export const ingestHealthBatch = Effect.fn("ingestHealthBatch")(function* (
  message: HealthBatchMessage,
) {
  const files = yield* HealthBatchFiles;
  const store = (yield* UserStores).forUser(message.userId);
  const key = healthBatchKey(message.userId, message.batchId);

  const known = yield* store.healthBatch(message.batchId);
  if (known?.status === "applied") return;
  const receivedAt = known?.receivedAt ?? (yield* Clock.currentTimeMillis);
  const finish = (batch: Omit<HealthBatch, "id" | "receivedAt" | "finishedAt">) =>
    Effect.gen(function* () {
      const finishedAt = yield* Clock.currentTimeMillis;
      yield* store.saveHealthBatch({ ...batch, id: message.batchId, receivedAt, finishedAt });
      yield* files.delete(key);
    });

  yield* store.saveHealthBatch({ id: message.batchId, status: "applying", receivedAt });
  const bytes = yield* files.get(key);
  if (Option.isNone(bytes)) {
    return yield* finish({ status: "failed", failure: "The batch file is missing" });
  }
  if (bytes.value.byteLength > maxHealthBatchBytes) {
    return yield* finish({ status: "failed", failure: "The batch file is too large" });
  }
  const parsed = yield* parseHealthBatch(bytes.value).pipe(Effect.result);
  if (Result.isFailure(parsed)) {
    return yield* finish({ status: "failed", failure: parsed.failure.message });
  }
  const { lines, rejected } = parsed.success;

  // Apply in chunks. If the store rejects a mutation (e.g. a new record missing a field), that
  // line is rejected and the rest of its chunk is tried again.
  let applied = 0;
  for (let start = 0; start < parsed.success.parsed.length; start += healthChunkSize) {
    const chunk = parsed.success.parsed.slice(start, start + healthChunkSize);
    while (chunk.length > 0) {
      const result = yield* store
        .applyMutations(chunk.map(({ mutation }) => mutation))
        .pipe(Effect.result);
      if (Result.isSuccess(result)) {
        applied += chunk.length;
        break;
      }
      const error = result.failure;
      if (error._tag !== "InvalidMutation") return yield* error;
      const [invalid] = chunk.splice(error.index, 1);
      if (invalid !== undefined) rejected.push({ line: invalid.line, message: error.message });
    }
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

/**
 * Marks a batch failed after its last delivery attempt, so its status doesn't stay `applying`.
 * The message then goes to the dead-letter queue.
 */
export const failHealthBatch = Effect.fn("failHealthBatch")(function* (
  message: HealthBatchMessage,
  failure: string,
) {
  const store = (yield* UserStores).forUser(message.userId);
  const known = yield* store.healthBatch(message.batchId);
  const now = yield* Clock.currentTimeMillis;
  yield* store.saveHealthBatch({
    id: message.batchId,
    status: "failed",
    receivedAt: known?.receivedAt ?? now,
    finishedAt: now,
    failure,
  });
});
