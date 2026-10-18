import { assert, describe, it } from "@effect/vitest";
import type * as Cloudflare from "alchemy/Cloudflare";
import { Effect, Exit, Fiber } from "effect";
import { TestClock } from "effect/testing";
import { deleteCallsAtOnce, deleteChunkKeys, deleteObjects } from "../src/Runtime.ts";

type Bucket = Pick<Cloudflare.R2.ReadWriteBucketClient, "delete">;
/** The fake buckets need no runtime context, which the real one's calls do. */
const run = (bucket: Bucket, keys: ReadonlyArray<string>) =>
  deleteObjects(bucket, keys) as Effect.Effect<void, unknown>;

const throttled = new Error(
  "delete: Reduce your concurrent request rate for the same object. (10058)",
);

/** A bucket whose deletes fail with `failure` the first `failures` times. */
const failing = (failures: number, failure: Error) => {
  let attempts = 0;
  const bucket = {
    delete: () =>
      Effect.suspend(() => (++attempts <= failures ? Effect.fail(failure) : Effect.void)),
  } as unknown as Bucket;
  return { bucket, attempts: () => attempts };
};

describe("deleteObjects", () => {
  it.effect("deletes each key once, in calls of at most deleteChunkKeys, a few at once", () =>
    Effect.gen(function* () {
      const calls: Array<ReadonlyArray<string>> = [];
      let open = 0;
      let mostOpen = 0;
      // Each call takes a second, so the ones running at once overlap.
      const bucket = {
        delete: (keys: string | Array<string>) =>
          Effect.sync(() => {
            calls.push(typeof keys === "string" ? [keys] : keys);
            mostOpen = Math.max(mostOpen, ++open);
          }).pipe(
            Effect.andThen(Effect.sleep("1 second")),
            Effect.ensuring(Effect.sync(() => void open--)),
          ),
      } as unknown as Bucket;
      const keys = Array.from(
        { length: deleteChunkKeys * (deleteCallsAtOnce + 2) + 50 },
        (_, index) => `part-${index}`,
      );
      const fiber = yield* Effect.forkChild(run(bucket, [...keys, ...keys.slice(0, 10)]));
      yield* TestClock.adjust("1 minute");
      yield* Fiber.join(fiber);
      assert.deepStrictEqual(
        calls.map((call) => call.length).toSorted((a, b) => b - a),
        [...Array.from({ length: deleteCallsAtOnce + 2 }, () => deleteChunkKeys), 50],
      );
      assert.deepStrictEqual(calls.flat().toSorted(), keys.toSorted());
      assert.strictEqual(mostOpen, deleteCallsAtOnce);
    }),
  );

  it.effect("makes every call when one fails, then fails", () =>
    Effect.gen(function* () {
      const calls: Array<ReadonlyArray<string>> = [];
      const broken = new Error("delete: Internal error (10001)");
      const bucket = {
        delete: (keys: Array<string>) =>
          Effect.suspend(() => {
            calls.push(keys);
            return calls.length === 1 ? Effect.fail(broken) : Effect.void;
          }),
      } as unknown as Bucket;
      const keys = Array.from({ length: deleteChunkKeys * 3 }, (_, index) => `part-${index}`);
      const exit = yield* Effect.exit(run(bucket, keys));
      assert.deepStrictEqual(exit, Exit.fail(broken));
      assert.deepStrictEqual(calls.flat().toSorted(), keys.toSorted());
    }),
  );

  it.effect("tries a throttled call again, up to 5 times", () =>
    Effect.gen(function* () {
      const recovers = failing(2, throttled);
      const fiber = yield* Effect.forkChild(run(recovers.bucket, ["a"]));
      yield* TestClock.adjust("1 minute");
      yield* Fiber.join(fiber);
      assert.strictEqual(recovers.attempts(), 3);

      const stays = failing(100, throttled);
      const exit = yield* Effect.forkChild(Effect.exit(run(stays.bucket, ["a"])));
      yield* TestClock.adjust("10 minutes");
      assert.isTrue((yield* Fiber.join(exit))._tag === "Failure");
      assert.strictEqual(stays.attempts(), 6);
    }),
  );

  it.effect("doesn't try other failures again", () =>
    Effect.gen(function* () {
      const broken = failing(100, new Error("delete: Unauthorized (10001)"));
      const exit = yield* Effect.exit(run(broken.bucket, ["a"]));
      assert.strictEqual(exit._tag, "Failure");
      assert.strictEqual(broken.attempts(), 1);
    }),
  );
});
