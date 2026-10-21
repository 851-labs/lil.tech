import { Effect, Layer } from "effect";
import { HttpRouter } from "effect/http";
import { Deployment } from "../src/Deployment.ts";
import { WorkerHttpLayer } from "../src/Http.ts";
import { RateLimits } from "../src/RateLimits.ts";
import { TestAppleKeys } from "./auth/TestApple.ts";
import { TestAppleTokens } from "./auth/TestAppleTokens.ts";
import { TestAuth } from "./auth/TestAuth.ts";
import { TestGoogleClients, TestGoogleKeys, TestGoogleWebClient } from "./auth/TestGoogle.ts";
import { TestHealthBlobs } from "./health/TestHealthBlobs.ts";
import { TestHealthIngestion } from "./health/TestHealthIngestion.ts";
import { TestUserStores } from "./store/TestUserStores.ts";

// The API as the Worker serves it, for tests that drive it with real Requests.

export type Handler = (request: Request) => Promise<Response>;

/**
 * Runs `use` with a handler for the same layer the Worker serves, driven with real Requests. The
 * handler and `use` share one test database, so `use` can seed it.
 */
export const withApi = <A, E>(
  use: (handler: Handler) => Effect.Effect<A, E, Layer.Success<typeof TestServices>>,
  deployment: Deployment["Service"] = { environment: "staging", version: "45aa829" },
  limits: RateLimits["Service"] = RateLimits.unlimited,
) =>
  Effect.gen(function* () {
    const services = Layer.mergeAll(
      TestServices,
      Layer.succeed(Deployment, deployment),
      Layer.succeed(RateLimits, limits),
    );
    const memoMap = yield* Layer.makeMemoMap;
    const context = yield* Layer.buildWithMemoMap(services, memoMap, yield* Effect.scope);
    const { handler, dispose } = HttpRouter.toWebHandler(
      WorkerHttpLayer.pipe(Layer.provide(services)),
      { memoMap },
    );
    yield* Effect.addFinalizer(() => Effect.promise(() => dispose()));
    return yield* use((request) => handler(request, context)).pipe(Effect.provide(context));
  }).pipe(Effect.scoped);

export const TestServices = Layer.mergeAll(
  TestAuth,
  TestAppleKeys,
  TestAppleTokens,
  TestGoogleKeys,
  TestGoogleClients,
  TestGoogleWebClient,
  TestUserStores,
  TestHealthIngestion,
  TestHealthBlobs,
);

export const send = (handler: Handler, request: Request) =>
  Effect.promise(async () => {
    const response = await handler(request);
    const text = await response.text();
    return {
      status: response.status,
      body: text === "" ? undefined : (JSON.parse(text) as unknown),
    };
  });
