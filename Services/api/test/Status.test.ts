import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
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
      const error = yield* Effect.flip(decodeStatus({ environment: "qa", version: "45aa829" }));
      assert.include(error.message, "environment");
      assert.notInclude(error.message, "version");
    }),
  );

  it.effect("rejects an empty version", () =>
    Effect.gen(function* () {
      const error = yield* Effect.flip(decodeStatus({ environment: "prod", version: "" }));
      assert.include(error.message, "version");
      assert.notInclude(error.message, "environment");
    }),
  );
});
