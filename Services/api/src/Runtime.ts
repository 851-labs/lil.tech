import * as Alchemy from "alchemy";
import type * as Cloudflare from "alchemy/Cloudflare";
import { Array as Arr, Effect, Stream } from "effect";

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

/** Deletes R2 objects by key, in calls of at most 1,000 keys, R2's limit. */
export const deleteObjects = (
  bucket: Pick<Cloudflare.R2.ReadWriteBucketClient, "delete">,
  keys: ReadonlyArray<string>,
) =>
  Effect.forEach(Arr.chunksOf(keys, 1000), (chunk) => bucket.delete([...chunk]), {
    discard: true,
  });
