import * as Alchemy from "alchemy";
import { Config, Context, Effect, Option } from "effect";
import { Environment } from "./Status.ts";

/** Which deployment is serving requests. */
export class Deployment extends Context.Service<
  Deployment,
  { readonly environment: Environment; readonly version: string }
>()("lil/api/Deployment") {
  /**
   * Reads `LIL_ENVIRONMENT` and `LIL_VERSION`. In the Worker this runs in the construction phase,
   * so Alchemy reads them from the deploy environment and binds them to the Worker.
   */
  static readonly config = Effect.gen(function* () {
    return {
      environment: yield* Config.Literals(Environment.literals, "LIL_ENVIRONMENT"),
      version: yield* Config.NonEmptyString("LIL_VERSION"),
    };
  });
}

/** The environment an Alchemy stage deploys. `alchemy dev` stages are named `dev_<user>`. */
/**
 * Custom domains per stage, for the API and the website. Other stages (PR previews, personal
 * stages) use workers.dev.
 */
export const stageDomains: Partial<
  Record<string, { readonly api: string; readonly site: string }>
> = {
  prod: { api: "api.lil.tech", site: "lil.tech" },
  staging: { api: "api.staging.lil.tech", site: "staging.lil.tech" },
};

export const environmentForStage = (stage: string): Environment => {
  if (stage === "prod" || stage === "staging") return stage;
  return stage.startsWith("dev_") ? "local" : "preview";
};

/**
 * R2 bucket props that let `alchemy destroy` delete a preview's buckets even when they hold
 * objects (`forceDestroy`). R2 refuses to delete a non-empty bucket, which left previews' buckets
 * behind when their PRs closed. Staging and prod keep that refusal as a safety net. Alchemy also
 * evaluates props inside the running Worker, where there's no `Stage`.
 */
export const disposableInPreviews = <Props extends object>(props: Props) =>
  Effect.gen(function* () {
    const stage = yield* Effect.serviceOption(Alchemy.Stage);
    const preview = Option.isSome(stage) && environmentForStage(stage.value) === "preview";
    const resolved: Props & { readonly forceDestroy?: boolean } = preview
      ? { ...props, forceDestroy: true }
      : props;
    return resolved;
  });
