import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import * as SQL from "alchemy/SQL/D1";
import { Config, Effect, Layer, Option, Redacted } from "effect";
import { HttpRouter } from "effect/http";
import { SessionKey } from "./auth/Tokens.ts";
import { CoreDatabase, CoreRepositories } from "./core/CoreDatabase.ts";
import { Deployment, environmentForStage } from "./Deployment.ts";
import { WorkerHttpLayer } from "./Http.ts";
import { UserStore } from "./store/UserStore.ts";
import { UserStores } from "./store/UserStores.ts";

/** Custom domains per stage. Other stages (PR previews, personal stages) use workers.dev. */
const domains: Partial<Record<string, string>> = {
  prod: "api.lil.tech",
  staging: "api.staging.lil.tech",
};

/**
 * The Worker's props. Alchemy also evaluates them inside the running Worker, where there's no
 * `Stage`, so the deploy-time work (picking the domain, checking the environment, binding the
 * session key) only happens when a stage is present. `sessionKey` makes the key at deploy time.
 */
export const makeApiWorkerProps = <Key, E, R>(sessionKey: Effect.Effect<Key, E, R>) =>
  Effect.gen(function* () {
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
    return {
      main,
      ...(domain === undefined ? {} : { domain }),
      env: { LIL_SESSION_KEY: yield* sessionKey },
    };
  });

// Generated once per stage and kept in Alchemy's state, so redeploys don't sign everyone out.
const apiWorkerProps = makeApiWorkerProps(Alchemy.makeRandom("SessionSigningKey"));

/**
 * The key that signs access tokens, bound by `apiWorkerProps`. It's only missing while Alchemy
 * plans a deploy, which runs the Worker's setup but never serves a request, so that gets a
 * throwaway random key. The deployed bundle (where Alchemy sets `__ALCHEMY_RUNTIME__`) refuses to
 * start without the real one.
 */
const readSessionKey = Effect.gen(function* () {
  const key = yield* Config.Redacted("LIL_SESSION_KEY").pipe(Config.option);
  if (Option.isSome(key)) return key.value;
  if (globalThis.__ALCHEMY_RUNTIME__) return yield* Effect.die("LIL_SESSION_KEY is not bound");
  return Redacted.make(crypto.randomUUID());
});

// Alchemy's Effect Worker entry imports the module's default export.
export default class ApiWorker extends Cloudflare.Worker<ApiWorker>()(
  "Api",
  apiWorkerProps,
  Effect.gen(function* () {
    const deployment = yield* Deployment.config;
    const key = yield* readSessionKey;
    const core = yield* Cloudflare.D1.QueryDatabase(CoreDatabase);
    const userStores = yield* UserStore;
    return {
      fetch: yield* HttpRouter.toHttpEffect(
        WorkerHttpLayer.pipe(
          Layer.provide(Layer.succeed(Deployment, deployment)),
          Layer.provide(Layer.succeed(SessionKey, key)),
          Layer.provide(Layer.succeed(UserStores, UserStores.fromNamespace(userStores))),
          Layer.provide(CoreRepositories.pipe(Layer.provideMerge(SQL.D1Layer(core)))),
        ),
      ),
    };
  }).pipe(Effect.provide(Cloudflare.D1.QueryDatabaseBinding)),
) {}
