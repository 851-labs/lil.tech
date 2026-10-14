import { assert, describe, it, layer } from "@effect/vitest";
import { ConfigProvider, Effect, Layer } from "effect";
import { HttpServer } from "effect/http";
import { HttpApiTest } from "effect/http-api";
import { Api } from "../src/Api.ts";
import { Deployment } from "../src/Deployment.ts";
import { SystemHandlers } from "../src/Http.ts";

const deployment = Layer.succeed(Deployment, { environment: "staging", version: "45aa829" });

layer(Layer.mergeAll(SystemHandlers.pipe(Layer.provide(deployment)), HttpServer.layerServices))(
  "GET /v1/status",
  (it) => {
    it.effect("returns the deployment's environment and version", () =>
      Effect.gen(function* () {
        const client = yield* HttpApiTest.groups(Api, ["system"]);
        const status = yield* client.status();
        assert.strictEqual(status.environment, "staging");
        assert.strictEqual(status.version, "45aa829");
      }),
    );
  },
);

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
      const error = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "prod" }),
        Effect.flip,
      );
      assert.include(String(error), "LIL_VERSION");
    }),
  );
});
