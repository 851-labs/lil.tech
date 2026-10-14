import { assert, describe, it } from "@effect/vitest";
import { Effect, Exit } from "effect";
import { decodeStatus, Status } from "../src/Status.ts";

describe("Status", () => {
  it.effect("decodes a valid status", () =>
    Effect.gen(function* () {
      const status = yield* decodeStatus({ environment: "staging", version: "45aa829" });
      assert.instanceOf(status, Status);
      assert.strictEqual(status.environment, "staging");
    }),
  );

  it.effect("rejects an unknown environment", () =>
    Effect.gen(function* () {
      const exit = yield* Effect.exit(decodeStatus({ environment: "qa", version: "45aa829" }));
      assert.isTrue(Exit.isFailure(exit));
    }),
  );
});
