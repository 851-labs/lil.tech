import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect, type Layer, Option, Stream } from "effect";
import type { Users } from "../core/Users.ts";
import { DisposableBucket } from "../Deployment.ts";
import {
  failHealthBatch,
  BatchFilesUnavailable,
  HealthBatchFiles,
  type HealthBatchMessage,
  HealthBatchQueue,
  ingestHealthBatch,
} from "./HealthIngestion.ts";
import { deleteObjects, listObjects, objectBody, provideRuntime } from "../Runtime.ts";
import { UserStores } from "../store/UserStores.ts";

// Resource IDs are also the Worker's binding names, so they must differ from each other.

/**
 * Uploaded batch files, kept until they're applied. Any left behind (a failed batch, an upload
 * whose queueing failed) expire after 7 days.
 */
export const HealthBatchBucket = DisposableBucket("HealthBatchFiles", {
  lifecycleRules: [
    {
      id: "expire-batch-files",
      deleteObjectsTransition: { condition: { type: "Age", maxAge: 7 * 24 * 60 * 60 } },
    },
  ],
});
export const HealthBatchQueueResource = Cloudflare.Queues.Queue("HealthBatchQueue");

/** Where a batch's message goes after its last failed attempt, to be looked at by hand. */
export const HealthBatchDeadLetters = Cloudflare.Queues.Queue("HealthBatchDeadLetters");

/**
 * Retries per batch after its first delivery fails. Cloudflare counts retries, so a message is
 * delivered at most this many times plus one before it's dead-lettered.
 */
export const maxHealthBatchRetries = 5;

/**
 * How many messages the queue handles at once, across users. Each store applies at most
 * `healthBatchesAtOnce` of its own, and turns the rest away quickly, so this is a few users'
 * batches plus those being turned away. Not more, because the consumers can share an isolate,
 * and each applying holds up to two chunks (`healthChunkBytes`) and their mutations.
 */
export const healthBatchConsumers = 16;

/**
 * Deletes every object in `bucket` whose key starts with `prefix`: a page of keys at a time (R2
 * lists up to 1,000), each deleted in one call.
 */
export const deletePrefix = (
  bucket: Pick<Cloudflare.R2.ReadWriteBucketClient, "list" | "delete">,
  prefix: string,
) =>
  listObjects(bucket, prefix).pipe(
    Effect.flatMap((objects) =>
      deleteObjects(
        bucket,
        objects.map((object) => object.key),
      ),
    ),
    Effect.mapError((error) => new BatchFilesUnavailable({ message: String(error) })),
  );

/**
 * Binds the batch bucket and queue and consumes the queue, in the Worker's setup. Returns
 * `HealthBatchFiles` and `HealthBatchQueue` as effects that build them from the runtime context
 * their binding calls need, which exists per request and per queue message, not during setup.
 */
export const HealthIngestionWorker = Effect.fnUntraced(function* (
  userStores: UserStores["Service"],
  /** The core `Users` repository, built per message (its D1 calls need the runtime context). */
  users: Layer.Layer<Users>,
) {
  const bucket = yield* Cloudflare.R2.ReadWriteBucket(yield* HealthBatchBucket);
  const queueResource = yield* HealthBatchQueueResource;
  const queue = yield* Cloudflare.Queues.WriteQueue(queueResource);
  const deadLetters = yield* HealthBatchDeadLetters;

  const files = Effect.map(Alchemy.RuntimeContext, (runtime) => {
    const inRuntime = provideRuntime(runtime);
    return HealthBatchFiles.of({
      put: (key, bytes) =>
        inRuntime(
          bucket.put(key, bytes, { httpMetadata: { contentType: "application/gzip" } }),
        ).pipe(Effect.asVoid, Effect.orDie),
      open: (key) =>
        inRuntime(bucket.get(key)).pipe(
          Effect.map((object) =>
            object === null ? Option.none() : Option.some(objectBody(object)),
          ),
          Effect.orDie,
        ),
      delete: (key) => inRuntime(bucket.delete(key)).pipe(Effect.orDie),
      deletePrefix: (prefix) => deletePrefix(bucket, prefix).pipe(inRuntime),
    });
  });
  const queueService = Effect.map(Alchemy.RuntimeContext, (runtime) =>
    HealthBatchQueue.of({
      send: (message, { delaySeconds } = {}) =>
        provideRuntime(runtime)(
          delaySeconds === undefined
            ? queue.send(message)
            : // Alchemy's `SendOptions` leave out `delaySeconds`; the binding's own `send` takes it.
              Effect.flatMap(queue.raw, (raw) =>
                Effect.tryPromise(() => raw.send(message, { delaySeconds })),
              ).pipe(Effect.asVoid, Effect.orDie),
        ).pipe(Effect.orDie),
    }),
  );

  yield* Cloudflare.Queues.consumeQueueMessages<HealthBatchMessage>(
    queueResource,
    {
      // One batch file per invocation, so a failure only retries that file.
      batchSize: 1,
      // Batches from many users at once. Each store limits how many of its own it applies at
      // once (`healthBatchesAtOnce`), and puts the rest back (851-2652).
      maxConcurrency: healthBatchConsumers,
      maxRetries: maxHealthBatchRetries,
      retryDelay: "30 seconds",
      // The queue's name, resolved at deploy time.
      deadLetterQueue: deadLetters.queueName as unknown as string,
    },
    (stream) =>
      Stream.runForEach(stream, (message) =>
        ingestHealthBatch(message.body).pipe(
          Effect.matchCauseEffect({
            onSuccess: (result) =>
              result === undefined
                ? Effect.sync(() => message.ack())
                : // Not its turn: back in the queue as a new message, delayed, so waiting holds no
                  // consumer and doesn't use up its retries.
                  Effect.flatMap(queueService, (queue) =>
                    queue.send(message.body, { delaySeconds: result.waitSeconds }),
                  ).pipe(
                    Effect.matchCause({
                      onSuccess: () => message.ack(),
                      // Not sent: retried as usual instead.
                      onFailure: () => message.retry(),
                    }),
                  ),
            onFailure: (cause) =>
              Effect.gen(function* () {
                yield* Effect.logWarning("Health batch failed", cause);
                // `attempts` starts at 1, so the last delivery is retry number `maxRetries`.
                if (message.attempts > maxHealthBatchRetries) {
                  yield* failHealthBatch(message.body, "Applying the batch kept failing").pipe(
                    Effect.ignore,
                  );
                }
                message.retry();
              }),
          }),
          Effect.provideServiceEffect(HealthBatchFiles, files),
          Effect.provideService(UserStores, userStores),
          Effect.provide(users),
        ),
      ),
  );

  return { files, queue: queueService };
});
