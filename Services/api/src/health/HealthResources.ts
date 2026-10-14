import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect, Option, Stream } from "effect";
import {
  failHealthBatch,
  HealthBatchFiles,
  type HealthBatchMessage,
  HealthBatchQueue,
  ingestHealthBatch,
} from "./HealthIngestion.ts";
import { UserStores } from "../store/UserStores.ts";

/** Uploaded batch files, kept until they're applied. */
export const HealthBatchBucket = Cloudflare.R2.Bucket("HealthBatches");
export const HealthBatchQueueResource = Cloudflare.Queues.Queue("HealthBatches");
/** Where a batch's message goes after its last failed attempt, to be looked at by hand. */
export const HealthBatchDeadLetters = Cloudflare.Queues.Queue("HealthBatchesDead");

/** Delivery attempts per batch before it's marked failed and dead-lettered. */
export const maxHealthBatchAttempts = 5;

/**
 * Binds the batch bucket and queue and consumes the queue, in the Worker's setup. Returns
 * `HealthBatchFiles` and `HealthBatchQueue` as effects that build them from the runtime context
 * their binding calls need, which exists per request and per queue message, not during setup.
 */
export const HealthIngestionWorker = Effect.fnUntraced(function* (
  userStores: UserStores["Service"],
) {
  const bucket = yield* Cloudflare.R2.ReadWriteBucket(yield* HealthBatchBucket);
  const queueResource = yield* HealthBatchQueueResource;
  const queue = yield* Cloudflare.Queues.WriteQueue(queueResource);
  const deadLetters = yield* HealthBatchDeadLetters;

  const files = Effect.map(Alchemy.RuntimeContext, (runtime) => {
    const inRuntime = <A, E>(effect: Effect.Effect<A, E, Alchemy.RuntimeContext>) =>
      Effect.provideService(effect, Alchemy.RuntimeContext, runtime);
    return HealthBatchFiles.of({
      put: (key, bytes) =>
        inRuntime(
          bucket.put(key, bytes, { httpMetadata: { contentType: "application/gzip" } }),
        ).pipe(Effect.asVoid, Effect.orDie),
      get: (key) =>
        inRuntime(
          bucket
            .get(key)
            .pipe(
              Effect.flatMap((object) =>
                object === null ? Effect.succeedNone : object.bytes().pipe(Effect.map(Option.some)),
              ),
            ),
        ).pipe(Effect.orDie),
      delete: (key) => inRuntime(bucket.delete(key)).pipe(Effect.orDie),
    });
  });
  const queueService = Effect.map(Alchemy.RuntimeContext, (runtime) =>
    HealthBatchQueue.of({
      send: (message) =>
        queue
          .send(message)
          .pipe(Effect.provideService(Alchemy.RuntimeContext, runtime), Effect.orDie),
    }),
  );

  yield* Cloudflare.Queues.consumeQueueMessages<HealthBatchMessage>(
    queueResource,
    {
      // One batch file per invocation, so a failure only retries that file.
      batchSize: 1,
      maxRetries: maxHealthBatchAttempts,
      retryDelay: "30 seconds",
      // The queue's name, resolved at deploy time.
      deadLetterQueue: deadLetters.queueName as unknown as string,
    },
    (stream) =>
      Stream.runForEach(stream, (message) =>
        ingestHealthBatch(message.body).pipe(
          Effect.matchCauseEffect({
            onSuccess: () => Effect.sync(() => message.ack()),
            onFailure: (cause) =>
              Effect.gen(function* () {
                yield* Effect.logWarning("Health batch failed", cause);
                if (message.attempts >= maxHealthBatchAttempts) {
                  yield* failHealthBatch(message.body, "Applying the batch kept failing").pipe(
                    Effect.ignore,
                  );
                }
                message.retry();
              }),
          }),
          Effect.provideServiceEffect(HealthBatchFiles, files),
          Effect.provideService(UserStores, userStores),
        ),
      ),
  );

  return { files, queue: queueService };
});
