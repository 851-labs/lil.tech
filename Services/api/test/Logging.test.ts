import { assert, describe, it } from "@effect/vitest";
import { EffectDrizzleQueryError } from "drizzle-orm/effect-core";
import { Cause, Console, Data, Effect, Redacted, Schema } from "effect";
import { HttpApiError } from "effect/http-api";
import { SqlError } from "effect/sql";
import { asSqlError, first } from "../src/core/CoreDb.ts";
import { Identity } from "../src/core/Identities.ts";
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

/** An error with fields that hold values (synthetic), next to a code that's safe to log. */
class Holding extends Data.TaggedError("Holding")<{
  readonly message: string;
  readonly appleError?: string;
  readonly sample?: unknown;
  readonly email?: string;
}> {}

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
      assert.deepStrictEqual(entry["details"], [
        { _tag: "Failed", name: "Failed", message: "Nope" },
      ]);
      assert.match(String(entry["cause"]), /D1 is down/);
    }),
  );

  it.effect("keeps redacted values redacted, and annotations can't replace its own fields", () =>
    Effect.gen(function* () {
      const lines = yield* logged(
        Effect.logInfo("Signed in", { token: Redacted.make("secret") }).pipe(
          Effect.annotateLogs({
            message: "replaced",
            level: "error",
            cause: "not a cause",
            key: Redacted.make("secret"),
          }),
        ),
      );
      const entry = lines[0]?.args[0] as Record<string, unknown>;
      assert.strictEqual(entry["message"], "Signed in");
      assert.strictEqual(entry["level"], "info");
      assert.notProperty(entry, "cause");
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

/** What `logged` wrote, as one string, to search for values that mustn't be there. */
const text = (lines: ReadonlyArray<{ readonly args: ReadonlyArray<unknown> }>) =>
  JSON.stringify(lines.map((line) => line.args));

/** Logs `effect`'s failure as our warnings do: the error as a detail, and the cause. */
const loggedFailure = <A, E>(effect: Effect.Effect<A, E>) =>
  logged(
    effect.pipe(
      Effect.catchCause((cause) =>
        Effect.logWarning("Snapshot step failed", Cause.squash(cause), cause),
      ),
    ),
  );

/** An identity row as the core database has it: synthetic, but the kind of thing it holds. */
const identityRow = {
  id: "idt_0123456789abcdefghjkmnpqrs",
  userId: "usr_0123456789abcdefghjkmnpqrs",
  provider: "apple",
  subject: "synthetic-subject-1234",
  email: 4054,
  emailVerified: "synthetic-flag",
  createdAt: 1,
};

describe("workersLogger's redaction (851-4054)", () => {
  it.effect("logs a row decoder's paths and expected types, never what it got", () =>
    Effect.gen(function* () {
      const decoders = [
        Schema.decodeUnknownEffect(Identity),
        // Decoding that reports its input, which the formatted message would show.
        (row: unknown) =>
          Schema.decodeUnknownEffect(Identity)(row, { reportInput: true, errors: "all" }),
      ];
      for (const decode of decoders) {
        const lines = yield* loggedFailure(first(decode)([identityRow]));
        const logged = text(lines);
        assert.include(logged, "Expected string | null");
        assert.include(logged, String.raw`at [\"email\"]`);
        assert.include(logged, "SchemaError");
        assert.notInclude(logged, "4054");
        assert.notInclude(logged, "synthetic-flag");
      }
    }),
  );

  it.effect("never logs a value D1 couldn't bind, or text that isn't JSON", () =>
    Effect.gen(function* () {
      const bind = new SqlError.SqlError({
        reason: new SqlError.UnknownError({
          cause: new Error(
            "D1_TYPE_ERROR: Type 'object' not supported for value 'synthetic-token-4054'",
          ),
          message: "Failed to execute statement",
        }),
      });
      const json = Effect.try(() => JSON.parse('{"value": synthetic-heart-rate-4054}'));
      const lines = [...(yield* loggedFailure(Effect.fail(bind))), ...(yield* loggedFailure(json))];
      const logged = text(lines);
      assert.include(logged, "D1_TYPE_ERROR: Type 'object' not supported for value <redacted>");
      assert.include(logged, "is not valid JSON");
      assert.notInclude(logged, "synthetic-token-4054");
      assert.notInclude(logged, "synthetic-heart-rate-4054");
    }),
  );

  it.effect("never logs a Drizzle query's parameters, even before asSqlError", () =>
    Effect.gen(function* () {
      const lines = yield* loggedFailure(
        Effect.die(
          new EffectDrizzleQueryError({
            query: "insert into identities (email) values (?)",
            params: ["synthetic@example.com"],
            cause: Cause.die(new Error("D1 went away")),
          }),
        ),
      );
      const logged = text(lines);
      assert.include(logged, "Failed query: insert into identities (email) values (?)");
      assert.include(logged, "D1 went away");
      assert.notInclude(logged, "synthetic@example.com");
    }),
  );

  it.effect("logs an error's type, message and codes, and its other fields' types only", () =>
    Effect.gen(function* () {
      const lines = yield* loggedFailure(
        Effect.fail(
          new Holding({
            message: "Applying the sample failed",
            appleError: "invalid_grant",
            sample: { value: 4054.5, unit: "count/min" },
            email: "synthetic@example.com",
          }),
        ),
      );
      const details = lines[0]?.args[0] as { details: ReadonlyArray<Record<string, unknown>> };
      assert.deepInclude(details.details[0], {
        _tag: "Holding",
        message: "Applying the sample failed",
        appleError: "invalid_grant",
        sample: "<object>",
        email: "<string>",
      });
      const logged = text(lines);
      assert.notInclude(logged, "4054.5");
      assert.notInclude(logged, "synthetic@example.com");
    }),
  );

  it.effect("logs a failure that isn't an error by its shape", () =>
    Effect.gen(function* () {
      const lines = yield* loggedFailure(
        Effect.fail({ quantity: 4054.5, note: "synthetic note", tags: ["synthetic tag"] }),
      );
      const logged = text(lines);
      assert.include(logged, "quantity");
      assert.notInclude(logged, "4054.5");
      assert.notInclude(logged, "synthetic note");
      assert.notInclude(logged, "synthetic tag");
    }),
  );

  it.effect("redacts a request body's decode error, nested as an HttpApi error's cause", () =>
    Effect.gen(function* () {
      const body = Schema.Struct({ displayName: Schema.Number });
      const lines = yield* loggedFailure(
        HttpApiError.HttpApiSchemaError.wrap(
          "Payload",
          Schema.decodeUnknownEffect(body)(
            { displayName: "Synthetic Name 4054" },
            { reportInput: true },
          ),
        ),
      );
      const logged = text(lines);
      assert.include(logged, "HttpApiSchemaError");
      assert.include(logged, "Payload");
      assert.include(logged, String.raw`at [\"displayName\"]`);
      assert.notInclude(logged, "Synthetic Name 4054");
    }),
  );

  it.effect("redacts a cause logged alone, as McpServer logs a tool's defect", () =>
    Effect.gen(function* () {
      const lines = yield* logged(
        Effect.die(new Holding({ message: "Tool failed", sample: 4054.5, email: "a@b.c" })).pipe(
          Effect.catchCause((cause) => Effect.logError(cause)),
        ),
      );
      const entry = lines[0]?.args[0] as Record<string, unknown>;
      assert.strictEqual(lines[0]?.method, "error");
      assert.strictEqual(entry["message"], "Holding: Tool failed");
      assert.notInclude(text(lines), "4054.5");
      assert.notInclude(text(lines), "a@b.c");
    }),
  );

  it.effect("redacts an error logged as the message, and string details", () =>
    Effect.gen(function* () {
      const lines = yield* logged(
        Effect.logError(
          new Holding({ message: "Tool failed", email: "synthetic@example.com" }),
          `Store call applyMutations failed: SyntaxError: Unexpected token 's', "synthetic-line-4054" is not valid JSON`,
        ),
      );
      const entry = lines[0]?.args[0] as Record<string, unknown>;
      assert.include(String(entry["message"]), "Tool failed");
      assert.include(text(lines), "Store call applyMutations failed");
      assert.notInclude(text(lines), "synthetic@example.com");
      assert.notInclude(text(lines), "synthetic-line-4054");
    }),
  );

  it.effect("shows a failure's name and message only when it's an Error", () =>
    Effect.gen(function* () {
      const lines = yield* loggedFailure(
        Effect.fail({ name: "Synthetic's iPhone", message: "synthetic note", pushToken: "t" }),
      );
      const logged = text(lines);
      assert.include(logged, "pushToken");
      assert.notInclude(logged, "Synthetic's iPhone");
      assert.notInclude(logged, "synthetic note");
    }),
  );

  it.effect("ends at an error whose cause holds it, and keeps no array in a kept field", () =>
    Effect.gen(function* () {
      const error = new Holding({ message: "Wrapped", appleError: "invalid_grant" });
      Object.assign(error, { cause: Cause.die(error), status: ["synthetic-status-4054"] });
      const lines = yield* loggedFailure(Effect.fail(error));
      const logged = text(lines);
      assert.include(logged, "Holding: Wrapped");
      assert.include(logged, "invalid_grant");
      assert.notInclude(logged, "synthetic-status-4054");
    }),
  );

  it.effect("formats a bare Schema issue's paths, and keeps a message's other parts", () =>
    Effect.gen(function* () {
      const issue = yield* Schema.decodeUnknownEffect(Schema.Struct({ email: Schema.String }))(
        { email: 4054 },
        { reportInput: true },
      ).pipe(
        Effect.flip,
        Effect.map((error) => error.issue),
      );
      const lines = yield* logged(
        Effect.fail(issue).pipe(
          Effect.catchCause((cause) =>
            Effect.logWarning(
              "Store call failed",
              `Store call "applyMutations" for batch "b_1" failed: SyntaxError: Unexpected token 'x', "synthetic-line-4054" is not valid JSON`,
              cause,
            ),
          ),
        ),
      );
      const output = text(lines);
      assert.include(output, String.raw`at [\"email\"]`);
      assert.include(output, String.raw`Store call \"applyMutations\" for batch \"b_1\" failed`);
      assert.notInclude(output, "4054");
    }),
  );
});
