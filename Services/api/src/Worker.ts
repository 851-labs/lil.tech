import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect, Layer, Path } from "effect";
import { Etag, HttpPlatform, HttpRouter } from "effect/http";
import { Deployment } from "./Deployment.ts";
import { ApiRoutes } from "./Http.ts";

/** Custom domains per stage. Other stages (PR previews, personal stages) use workers.dev. */
const domains: Partial<Record<string, string>> = {
  prod: "api.lil.tech",
  staging: "api.staging.lil.tech",
};

// Workers have no file system, so file responses aren't supported. Compression is left to
// Cloudflare's edge, so the platform advertises no algorithms.
const HttpPlatformStub = Layer.succeed(HttpPlatform.HttpPlatform, {
  platform: "web",
  compression: {
    algorithms: new Set<HttpPlatform.CompressionAlgorithm>(),
    compressResponse: (response) => Effect.succeed(response),
  },
  fileResponse: () => Effect.die("HttpPlatform.fileResponse isn't supported on Workers"),
  fileWebResponse: () => Effect.die("HttpPlatform.fileWebResponse isn't supported on Workers"),
});

export class ApiWorker extends Cloudflare.Worker<ApiWorker>()(
  "Api",
  Effect.gen(function* () {
    const domain = domains[yield* Alchemy.Stage];
    return { main: import.meta.url, ...(domain === undefined ? {} : { domain }) };
  }),
  Effect.gen(function* () {
    const deployment = yield* Deployment.config;
    return {
      fetch: yield* HttpRouter.toHttpEffect(
        ApiRoutes.pipe(
          Layer.provide(Layer.succeed(Deployment, deployment)),
          Layer.provide([Etag.layer, HttpPlatformStub, Path.layer]),
        ),
      ),
    };
  }),
) {}
