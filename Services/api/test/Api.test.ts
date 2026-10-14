import { assert, describe, it } from "@effect/vitest";
import * as Alchemy from "alchemy";
import { ConfigProvider, Effect, Exit, Layer } from "effect";
import { HttpRouter } from "effect/http";
import { Deployment, environmentForStage } from "../src/Deployment.ts";
import { WorkerHttpLayer } from "../src/Http.ts";
import { apiWorkerProps } from "../src/Worker.ts";

describe("WorkerHttpLayer", () => {
  // The same layer the Worker serves, driven with real Requests.
  const { handler, dispose } = HttpRouter.toWebHandler(
    WorkerHttpLayer.pipe(
      Layer.provide(Layer.succeed(Deployment, { environment: "staging", version: "45aa829" })),
    ),
  );

  it.live("GET /v1/status returns the deployment's environment and version", () =>
    Effect.gen(function* () {
      const response = yield* Effect.promise(() =>
        handler(new Request("https://api.staging.lil.tech/v1/status")),
      );
      assert.strictEqual(response.status, 200);
      const body = yield* Effect.promise(() => response.json());
      assert.deepStrictEqual(body, { environment: "staging", version: "45aa829" });
    }).pipe(Effect.ensuring(Effect.promise(() => dispose()))),
  );

  it.live("unknown paths return 404", () =>
    Effect.gen(function* () {
      const { handler, dispose } = HttpRouter.toWebHandler(
        WorkerHttpLayer.pipe(
          Layer.provide(Layer.succeed(Deployment, { environment: "prod", version: "1" })),
        ),
      );
      const response = yield* Effect.promise(() =>
        handler(new Request("https://api.lil.tech/v1/nope")),
      );
      assert.strictEqual(response.status, 404);
      yield* Effect.promise(() => dispose());
    }),
  );
});

describe("Deployment.config", () => {
  const withEnv = (env: Record<string, string>) =>
    Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnvRecord(env)));

  it.effect("reads LIL_ENVIRONMENT and LIL_VERSION", () =>
    Effect.gen(function* () {
      const config = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "prod", LIL_VERSION: "45aa829" }),
      );
      assert.deepStrictEqual(config, { environment: "prod", version: "45aa829" });
    }),
  );

  it.effect("rejects an unknown environment", () =>
    Effect.gen(function* () {
      const error = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "qa", LIL_VERSION: "45aa829" }),
        Effect.flip,
      );
      assert.include(String(error), "LIL_ENVIRONMENT");
    }),
  );

  it.effect("requires a version", () =>
    Effect.gen(function* () {
      const missing = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "prod" }),
        Effect.flip,
      );
      assert.include(String(missing), "LIL_VERSION");
      const empty = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "prod", LIL_VERSION: "" }),
        Effect.flip,
      );
      assert.include(String(empty), "LIL_VERSION");
    }),
  );
});

describe("environmentForStage", () => {
  it("maps stages to environments", () => {
    assert.strictEqual(environmentForStage("prod"), "prod");
    assert.strictEqual(environmentForStage("staging"), "staging");
    assert.strictEqual(environmentForStage("pr-12"), "preview");
    assert.strictEqual(environmentForStage("live_tuftlord"), "preview");
    assert.strictEqual(environmentForStage("dev_tuftlord"), "local");
  });
});

describe("apiWorkerProps", () => {
  const withEnv = (env: Record<string, string>) =>
    Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnvRecord(env)));

  it.effect("runs without a Stage, as it does inside the deployed Worker", () =>
    Effect.gen(function* () {
      const props = yield* apiWorkerProps;
      assert.isUndefined((props as { domain?: string }).domain);
    }),
  );

  it.effect("picks the custom domain for the stage at deploy time", () =>
    Effect.gen(function* () {
      const props = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "staging"),
        withEnv({ LIL_ENVIRONMENT: "staging", LIL_VERSION: "45aa829" }),
      );
      assert.strictEqual((props as { domain?: string }).domain, "api.staging.lil.tech");
    }),
  );

  it.effect("refuses an environment that doesn't match the stage", () =>
    Effect.gen(function* () {
      const exit = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "prod"),
        withEnv({ LIL_ENVIRONMENT: "staging", LIL_VERSION: "45aa829" }),
        Effect.exit,
      );
      assert.isTrue(Exit.isFailure(exit));
    }),
  );
});
