import { assert, describe, it } from "@effect/vitest";
import type * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { deleteChunkKeys, deleteObjects } from "../src/Runtime.ts";

type Bucket = Pick<Cloudflare.R2.ReadWriteBucketClient, "delete">;
/** The fake buckets need no runtime context, which the real one's calls do. */
const run = (bucket: Bucket, keys: ReadonlyArray<string>) =>
  deleteObjects(bucket, keys) as Effect.Effect<void, unknown>;

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

  it.live("tries a throttled call again", () =>
    Effect.gen(function* () {
      let attempts = 0;
      const bucket = {
        delete: () =>
          Effect.suspend(() =>
            ++attempts === 1
              ? Effect.fail(new Error("Reduce your concurrent request rate (10058)"))
              : Effect.void,
          ),
      } as unknown as Bucket;
      yield* run(bucket, ["a", "b"]);
      assert.strictEqual(attempts, 2);
    }),
  );
});
