import * as Alchemy from "alchemy";
import { Effect, Stream } from "effect";

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
