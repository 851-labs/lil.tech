import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
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
 * Custom domains per stage, for the API, the website and Pixelbook. Other stages (PR previews,
 * personal stages) use workers.dev.
 */
export const stageDomains: Partial<
  Record<string, { readonly api: string; readonly site: string; readonly pixelbook: string }>
> = {
  prod: { api: "api.lil.tech", site: "lil.tech", pixelbook: "pixelbook.lil.tech" },
  staging: {
    api: "api.staging.lil.tech",
    site: "staging.lil.tech",
    pixelbook: "pixelbook.staging.lil.tech",
  },
};

/**
 * Pixelbook's bucket of snapshots (851-2696), prod's only, which every stage's Pixelbook reads, and
 * the domain it's public at.
 */
export const pixelbookBucketName = "lil-pixelbook";
export const pixelbookAssetsDomain = "pixelbook-assets.lil.tech";

export const environmentForStage = (stage: string): Environment => {
  if (stage === "prod" || stage === "staging") return stage;
  return stage.startsWith("dev_") ? "local" : "preview";
};

/**
 * An R2 bucket that previews, personal stages and `alchemy dev` can delete even when it holds
 * objects (`forceDestroy`). R2 refuses to delete a non-empty bucket, which left preview buckets
 * behind when their PRs closed. Staging and prod keep that refusal as a safety net. Use it for
 * every bucket. Alchemy also evaluates props inside the running Worker, where there's no `Stage`.
 */
export const DisposableBucket = (id: string, props: Cloudflare.R2.BucketProps = {}) =>
  Cloudflare.R2.Bucket(id, disposableBucketProps(props));

/** `DisposableBucket`'s props: `forceDestroy` everywhere but staging and prod. */
export const disposableBucketProps = (props: Cloudflare.R2.BucketProps) =>
  Effect.gen(function* () {
    const stage = yield* Effect.serviceOption(Alchemy.Stage);
    const shared = Option.isNone(stage) || stage.value === "prod" || stage.value === "staging";
    return shared ? props : { ...props, forceDestroy: true };
  });
