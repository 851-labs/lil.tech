import * as Http from "alchemy/Http";
import { Effect, Layer } from "effect";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "./Api.ts";
import { Deployment } from "./Deployment.ts";
import { Status } from "./Status.ts";

export const SystemHandlers = HttpApiBuilder.group(
  Api,
  "system",
  Effect.fn(function* (handlers) {
    const status = new Status(yield* Deployment);
    return handlers.handle("status", () => Effect.succeed(status));
  }),
);

/**
 * Every route of the API, with the platform services a Worker can provide: Alchemy's
 * `Http.Platform` stubs file responses and gives `HttpApiBuilder` a no-op `FileSystem`, since
 * Workers have no file system. Needs `Deployment`.
 */
export const WorkerHttpLayer = HttpApiBuilder.layer(Api).pipe(
  Layer.provide(SystemHandlers),
  Layer.provide(Http.Platform),
);
