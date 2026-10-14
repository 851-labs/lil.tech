import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import * as SQL from "alchemy/SQL/D1";
import { Effect, Layer, Option } from "effect";
import { HttpRouter } from "effect/http";
import { CoreDatabase, CoreRepositories } from "./core/CoreDatabase.ts";
import { Deployment, environmentForStage } from "./Deployment.ts";
import { WorkerHttpLayer } from "./Http.ts";

/** Custom domains per stage. Other stages (PR previews, personal stages) use workers.dev. */
const domains: Partial<Record<string, string>> = {
  prod: "api.lil.tech",
  staging: "api.staging.lil.tech",
};

/**
 * The Worker's props. Alchemy also evaluates them inside the running Worker, where there's no
 * `Stage`, so the deploy-time work (picking the domain, checking the environment) only happens
 * when a stage is present.
 */
export const apiWorkerProps = Effect.gen(function* () {
  const main = import.meta.url;
  const stage = yield* Effect.serviceOption(Alchemy.Stage);
  if (Option.isNone(stage)) return { main };
  const { environment } = yield* Deployment.config;
  const expected = environmentForStage(stage.value);
  if (environment !== expected) {
    return yield* Effect.die(
      `LIL_ENVIRONMENT is "${environment}" but stage "${stage.value}" expects "${expected}"`,
    );
  }
  const domain = domains[stage.value];
  return { main, ...(domain === undefined ? {} : { domain }) };
});

// Alchemy's Effect Worker entry imports the module's default export.
export default class ApiWorker extends Cloudflare.Worker<ApiWorker>()(
  "Api",
  apiWorkerProps,
  Effect.gen(function* () {
    const deployment = yield* Deployment.config;
    const core = yield* Cloudflare.D1.QueryDatabase(CoreDatabase);
    return {
      fetch: yield* HttpRouter.toHttpEffect(
        WorkerHttpLayer.pipe(
          Layer.provide(Layer.succeed(Deployment, deployment)),
          Layer.provide(CoreRepositories.pipe(Layer.provideMerge(SQL.D1Layer(core)))),
        ),
      ),
    };
  }).pipe(Effect.provide(Cloudflare.D1.QueryDatabaseBinding)),
) {}
