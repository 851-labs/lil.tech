import { Context, Effect, Layer } from "effect";
import { HealthBlobFiles } from "../../src/health/HealthBlobs.ts";
import { openStored } from "../store/TestUserStores.ts";

/** What the test blob bucket holds, for assertions. */
export class TestHealthBlobBucket extends Context.Service<
  TestHealthBlobBucket,
  { readonly files: Map<string, Uint8Array> }
>()("test/TestHealthBlobBucket") {}

/** In-memory `HealthBlobFiles`, with `TestHealthBlobBucket` to inspect them. */
export const TestHealthBlobs = Layer.unwrap(
  Effect.sync(() => {
    const files = new Map<string, Uint8Array>();
    return Layer.mergeAll(
      Layer.succeed(TestHealthBlobBucket, { files }),
      Layer.succeed(
        HealthBlobFiles,
        HealthBlobFiles.of({
          put: (key, bytes) => Effect.sync(() => void files.set(key, bytes)),
          delete: (key) => Effect.sync(() => void files.delete(key)),
          open: openStored(files),
          deletePrefix: (prefix) =>
            Effect.sync(() => {
              // Deleting the entry being visited is safe while iterating a Map.
              for (const key of files.keys()) if (key.startsWith(prefix)) files.delete(key);
            }),
        }),
      ),
    );
  }),
);
