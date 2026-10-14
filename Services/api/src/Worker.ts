import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect, Layer } from "effect";
import { HttpRouter } from "effect/http";
import { Deployment, environmentForStage } from "./Deployment.ts";
import { WorkerHttpLayer } from "./Http.ts";

/** Custom domains per stage. Other stages (PR previews, personal stages) use workers.dev. */
const domains: Partial<Record<string, string>> = {
  prod: "api.lil.tech",
  staging: "api.staging.lil.tech",
};

// Alchemy's Effect Worker entry imports the module's default export.
export default class ApiWorker extends Cloudflare.Worker<ApiWorker>()(
  "Api",
  // Props run only at deploy time, so this is where the deploy's configuration is checked.
  Effect.gen(function* () {
    const stage = yield* Alchemy.Stage;
    const { environment } = yield* Deployment.config;
    if (environment !== environmentForStage(stage)) {
      return yield* Effect.die(
        `LIL_ENVIRONMENT is "${environment}" but stage "${stage}" expects "${environmentForStage(stage)}"`,
      );
    }
    const domain = domains[stage];
    return { main: import.meta.url, ...(domain === undefined ? {} : { domain }) };
  }),
  Effect.gen(function* () {
    const deployment = yield* Deployment.config;
    return {
      fetch: yield* HttpRouter.toHttpEffect(
        WorkerHttpLayer.pipe(Layer.provide(Layer.succeed(Deployment, deployment))),
      ),
    };
  }),
) {}
