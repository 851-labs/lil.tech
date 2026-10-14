import { Effect, Layer } from "effect";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "./Api.ts";
import { Deployment } from "./Deployment.ts";
import { Status } from "./Status.ts";

export const SystemHandlers = HttpApiBuilder.group(
  Api,
  "system",
  Effect.fn(function* (handlers) {
    const deployment = yield* Deployment;
    return handlers.handle("status", () => Effect.succeed(new Status(deployment)));
  }),
);

/** Every route of the API. Needs `Deployment` and the HTTP platform services. */
export const ApiRoutes = HttpApiBuilder.layer(Api).pipe(Layer.provide(SystemHandlers));
