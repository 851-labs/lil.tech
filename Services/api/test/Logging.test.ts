import { assert, describe, it } from "@effect/vitest";
import { EffectDrizzleQueryError } from "drizzle-orm/effect-core";
import { Cause, Console, Data, Effect, Redacted } from "effect";
import { asSqlError } from "../src/core/CoreDb.ts";
import { WorkersLogs } from "../src/Logging.ts";

/** What `workersLogger` sent to the console: the method it called and its one argument. */
const logged = <A, E>(effect: Effect.Effect<A, E>) =>
  Effect.gen(function* () {
    const lines: Array<{ method: string; args: ReadonlyArray<unknown> }> = [];
    const record =
      (method: string) =>
      (...args: ReadonlyArray<unknown>) =>
        void lines.push({ method, args });
    const console = {
      ...globalThis.console,
      debug: record("debug"),
      info: record("info"),
      log: record("log"),
      warn: record("warn"),
      error: record("error"),
    };
    yield* effect.pipe(
      Effect.provide(WorkersLogs),
      Effect.provideService(Console.Console, console as unknown as Console.Console),
    );
    return lines;
  });

class Failed extends Data.TaggedError("Failed")<{ readonly message: string }> {}

describe("workersLogger", () => {
  it.effect("logs one object, at its level, with the annotations as fields", () =>
    Effect.gen(function* () {
      const lines = yield* logged(
        Effect.gen(function* () {
          yield* Effect.logInfo("Agent tool call").pipe(
            Effect.annotateLogs({ tool: "summary", grant: "grant-1", durationMs: 12, bytes: 340 }),
          );
          yield* Effect.logWarning("Health batch failed");
          yield* Effect.logError("Deleting the store failed");
          yield* Effect.logDebug("Closing a socket failed");
        }),
      );
      assert.deepStrictEqual(lines, [
        {
          method: "info",
          args: [
            {
              tool: "summary",
              grant: "grant-1",
              durationMs: 12,
              bytes: 340,
              message: "Agent tool call",
              level: "info",
            },
          ],
        },
        { method: "warn", args: [{ message: "Health batch failed", level: "warn" }] },
        { method: "error", args: [{ message: "Deleting the store failed", level: "error" }] },
      ]);
    }),
  );

  it.effect("puts the other parts in details and the cause in cause", () =>
    Effect.gen(function* () {
      const lines = yield* logged(
        Effect.fail(new Failed({ message: "D1 is down" })).pipe(
          Effect.catchCause((cause) =>
            Effect.logWarning(
              "Revoking Apple tokens failed",
              new Failed({ message: "Nope" }),
              cause,
            ),
          ),
        ),
      );
      const [line] = lines;
      assert.strictEqual(line?.method, "warn");
      const entry = line?.args[0] as Record<string, unknown>;
      assert.strictEqual(entry["message"], "Revoking Apple tokens failed");
      assert.deepStrictEqual(entry["details"], [{ _tag: "Failed", message: "Nope" }]);
      assert.match(String(entry["cause"]), /D1 is down/);
    }),
  );

  it.effect("keeps redacted values redacted, and annotations can't replace the message", () =>
    Effect.gen(function* () {
      const lines = yield* logged(
        Effect.logInfo("Signed in", { token: Redacted.make("secret") }).pipe(
          Effect.annotateLogs({
            message: "replaced",
            level: "error",
            key: Redacted.make("secret"),
          }),
        ),
      );
      const entry = lines[0]?.args[0] as Record<string, unknown>;
      assert.strictEqual(entry["message"], "Signed in");
      assert.strictEqual(entry["level"], "info");
      assert.notInclude(JSON.stringify(entry), "secret");
    }),
  );

  it.effect("never logs a failed query's parameters", () =>
    Effect.gen(function* () {
      const error = asSqlError(
        new EffectDrizzleQueryError({
          query: "select * from sessions where token_hash = ?",
          params: ["token-hash"],
          cause: Cause.die(new Error("D1 went away")),
        }),
      );
      const lines = yield* logged(
        Effect.fail(error).pipe(
          Effect.catchCause((cause) =>
            Effect.logWarning("Checking an agent token failed", error, cause),
          ),
        ),
      );
      const text = JSON.stringify(lines);
      assert.include(text, "select * from sessions where token_hash = ?");
      assert.include(text, "D1 went away");
      assert.notInclude(text, "token-hash");
    }),
  );
});
