import { gzipSync } from "node:zlib";
import { Context, Effect, Layer, Option } from "effect";
import {
  HealthBatchFiles,
  type HealthBatchMessage,
  HealthBatchQueue,
} from "../../src/health/HealthIngestion.ts";

/** What the test batch files and queue hold, for assertions. */
export class TestHealthOutbox extends Context.Service<
  TestHealthOutbox,
  { readonly files: Map<string, Uint8Array>; readonly sent: Array<HealthBatchMessage> }
>()("test/TestHealthOutbox") {}

/** In-memory `HealthBatchFiles` and `HealthBatchQueue`, with `TestHealthOutbox` to inspect them. */
export const TestHealthIngestion = Layer.unwrap(
  Effect.sync(() => {
    const files = new Map<string, Uint8Array>();
    const sent: Array<HealthBatchMessage> = [];
    return Layer.mergeAll(
      Layer.succeed(TestHealthOutbox, { files, sent }),
      Layer.succeed(
        HealthBatchFiles,
        HealthBatchFiles.of({
          put: (key, bytes) => Effect.sync(() => void files.set(key, bytes)),
          get: (key) => Effect.sync(() => Option.fromNullishOr(files.get(key))),
          delete: (key) => Effect.sync(() => void files.delete(key)),
        }),
      ),
      Layer.succeed(
        HealthBatchQueue,
        HealthBatchQueue.of({ send: (message) => Effect.sync(() => void sent.push(message)) }),
      ),
    );
  }),
);

/** A batch file: one JSON value per line, gzip-compressed. */
export const batchFile = (lines: ReadonlyArray<unknown>) =>
  new Uint8Array(
    gzipSync(
      lines.map((line) => (typeof line === "string" ? line : JSON.stringify(line))).join("\n"),
    ),
  );
