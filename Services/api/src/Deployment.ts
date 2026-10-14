import { Config, Context, Effect, Layer } from "effect";
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

  static readonly layerConfig = Layer.effect(Deployment, Deployment.config);
}
