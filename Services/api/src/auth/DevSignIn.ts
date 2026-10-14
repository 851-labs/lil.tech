import { Effect, Schema } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { Devices, DevicePlatform } from "../core/Devices.ts";
import { Users } from "../core/Users.ts";
import { Deployment } from "../Deployment.ts";
import type { Environment } from "../Status.ts";
import { Auth } from "./Auth.ts";
import { TokenPair } from "./AuthApi.ts";

/** Where dev sign-in exists. Never staging or prod, which hold real accounts. */
export const devSignInEnvironments: ReadonlySet<Environment> = new Set(["preview", "local"]);

const DevSignInRequest = Schema.Struct({
  displayName: Schema.optionalKey(Schema.NullOr(Schema.String)),
  app: Schema.optionalKey(Schema.NonEmptyString),
  platform: Schema.optionalKey(DevicePlatform),
});

/**
 * `POST /v1/auth/dev`: signs in as a new synthetic user with no identities, for checking PR
 * previews end to end and for simulator builds while provider sign-in isn't available. It's left
 * out of the OpenAPI spec, and only registered in `devSignInEnvironments`; elsewhere it's a 404.
 */
export const DevSignInRoute = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    if (!devSignInEnvironments.has(environment)) return;
    const users = yield* Users;
    const devices = yield* Devices;
    const auth = yield* Auth;
    yield* router.add(
      "POST",
      "/v1/auth/dev",
      Effect.gen(function* () {
        const request = yield* HttpServerRequest.schemaBodyJson(DevSignInRequest);
        const user = yield* users.create({ displayName: request.displayName ?? null });
        const device = yield* devices.create({
          userId: user.id,
          app: request.app ?? "dev",
          platform: request.platform ?? "macos",
          name: "Dev sign-in",
        });
        const tokens = yield* auth.issueSession(user.id, device.id);
        return yield* HttpServerResponse.schemaJson(TokenPair)(tokens);
      }).pipe(
        Effect.catchTag("SchemaError", (error) =>
          Effect.succeed(
            HttpServerResponse.jsonUnsafe({ message: error.message }, { status: 400 }),
          ),
        ),
        Effect.orDie,
      ),
    );
  }),
);
