import * as Alchemy from "alchemy";
import type * as Cloudflare from "alchemy/Cloudflare";
import { Array as Arr, Effect, Exit, Predicate, Schedule, Stream } from "effect";

/**
 * Runs Alchemy binding calls (R2, queues) in a captured runtime context. Their calls need the
 * Worker's or Durable Object's runtime context, which code captures where it exists (a request,
 * a queue message, a running object) to call bindings from elsewhere.
 */
export const provideRuntime =
  (runtime: Alchemy.RuntimeContext["Service"]) =>
  <A, E>(effect: Effect.Effect<A, E, Alchemy.RuntimeContext>): Effect.Effect<A, E> =>
    Effect.provideService(effect, Alchemy.RuntimeContext, runtime);

/** An R2 object's body as a web stream: the platform's own when there is one. */
export const objectBody = (object: {
  readonly readable?: ReadableStream<Uint8Array> | undefined;
  readonly body: Stream.Stream<Uint8Array, unknown>;
}): ReadableStream<Uint8Array> =>
  object.readable ?? Stream.toReadableStream(object.body.pipe(Stream.orDie));

/** Every R2 object whose key starts with `prefix`: a page of keys at a time (R2 lists up to 1,000). */
export const listObjects = (bucket: Pick<Cloudflare.R2.ReadBucketClient, "list">, prefix: string) =>
  Effect.gen(function* () {
    const objects: Array<{ readonly key: string; readonly uploaded: number }> = [];
    let cursor: string | undefined;
    do {
      const page = yield* bucket.list({ prefix, ...(cursor === undefined ? {} : { cursor }) });
      for (const object of page.objects) {
        objects.push({ key: object.key, uploaded: object.uploaded.getTime() });
      }
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor !== undefined);
    return objects;
  });

/**
 * Deletes R2 objects by key, each once, in calls of `deleteChunkKeys`, `deleteCallsAtOnce` at a
 * time: a call takes as long as its slowest keys, and R2 has slow spells, so big calls were slow
 * (851-2655, `docs/DECISIONS.md`). R2 also throttles deletes ("Reduce your concurrent request rate
 * for the same object", 10058): it failed a prod store's wipe of 2,644 snapshot parts. A throttled
 * call is tried again after a growing, jittered pause; other failures aren't. Every call is made
 * even if one fails, so a failed delete leaves only that call's keys for next time, and then the
 * first failure is returned.
 */
export const deleteObjects = (
  bucket: Pick<Cloudflare.R2.ReadWriteBucketClient, "delete">,
  keys: ReadonlyArray<string>,
) =>
  Effect.forEach(
    Arr.chunksOf(Arr.dedupe(keys), deleteChunkKeys),
    (chunk) =>
      bucket.delete([...chunk]).pipe(
        Effect.retry({
          schedule: Schedule.exponential("500 millis").pipe(Schedule.jittered),
          times: 5,
          while: isThrottled,
        }),
        Effect.exit,
      ),
    { concurrency: deleteCallsAtOnce },
  ).pipe(Effect.flatMap((exits) => exits.find(Exit.isFailure) ?? Effect.void));

/** The most keys deleted per R2 call (R2 takes up to 1,000). */
export const deleteChunkKeys = 100;

/**
 * How many delete calls run at once: a Worker invocation keeps at most 6 connections waiting for
 * a response, R2 calls included, and more weren't faster.
 */
export const deleteCallsAtOnce = 6;

/** Whether R2 refused a call for its rate (error 10058). */
export const isThrottled = (error: unknown) =>
  [String(error), Predicate.hasProperty(error, "message") ? String(error.message) : ""].some(
    (text) => text.includes("(10058)"),
  );
