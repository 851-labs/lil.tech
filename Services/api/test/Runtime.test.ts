import { assert, describe, it } from "@effect/vitest";
import type * as Cloudflare from "alchemy/Cloudflare";
import { Effect, Fiber } from "effect";
import { TestClock } from "effect/testing";
import { deleteChunkKeys, deleteObjects } from "../src/Runtime.ts";

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
  it.effect("deletes each key once, in calls of at most deleteChunkKeys", () =>
    Effect.gen(function* () {
      const calls: Array<ReadonlyArray<string>> = [];
      const bucket = {
        delete: (keys: string | Array<string>) =>
          Effect.sync(() => void calls.push(typeof keys === "string" ? [keys] : keys)),
      } as unknown as Bucket;
      const keys = Array.from({ length: deleteChunkKeys + 50 }, (_, index) => `part-${index}`);
      yield* run(bucket, [...keys, ...keys.slice(0, 10)]);
      assert.deepStrictEqual(
        calls.map((call) => call.length),
        [deleteChunkKeys, 50],
      );
      assert.deepStrictEqual(calls.flat(), keys);
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
