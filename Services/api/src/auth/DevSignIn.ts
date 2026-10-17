import { Effect, Option, Schema } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { DevicePlatform, Devices } from "../core/Devices.ts";
import { Users } from "../core/Users.ts";
import { Deployment } from "../Deployment.ts";
import { checkAddressRateLimit, RateLimits, tooManyRequests } from "../RateLimits.ts";
import type { Environment } from "../Status.ts";
import { Auth } from "./Auth.ts";
import { TokenPair } from "./AuthApi.ts";

/** Where dev sign-in exists. Never staging or prod, which hold real accounts. */
export const devSignInEnvironments: ReadonlySet<Environment> = new Set(["preview", "local"]);

/**
 * How many users a stage may have before dev sign-in refuses. Previews are public on workers.dev,
 * so this bounds what anyone can make one create.
 */
export const maxDevUsers = 1000;

const DevSignInRequest = Schema.Struct({
  displayName: Schema.optionalKey(Schema.NullOr(Schema.String)),
  /**
   * A synthetic account to sign in to, by name, made the first time: so an iPhone and a Mac sign
   * in to the same one.
   */
  account: Schema.optionalKey(Schema.NonEmptyString),
  app: Schema.optionalKey(Schema.NonEmptyString),
  platform: Schema.optionalKey(DevicePlatform),
});

/** The request body, which may be empty. Only this can fail with a 400. */
const readRequest = Effect.gen(function* () {
  const text = yield* (yield* HttpServerRequest.HttpServerRequest).text;
  return yield* Schema.decodeUnknownEffect(Schema.fromJsonString(DevSignInRequest))(
    text.trim() === "" ? "{}" : text,
  );
});

const badRequest = (message: string) =>
  HttpServerResponse.jsonUnsafe({ _tag: "BadRequest", message }, { status: 400 });

/**
 * `POST /v1/auth/dev`: signs in as a synthetic user with no identities, for checking PR previews
 * end to end and for simulator and Debug Mac builds pointed at one. A new user each time, or the
 * one named `account`, made the first time, so several devices can share it. It's left out of the
 * OpenAPI spec, and only registered in `devSignInEnvironments`; elsewhere it's a 404.
 */
export const DevSignInRoute = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    if (!devSignInEnvironments.has(environment)) return;
    const users = yield* Users;
    const devices = yield* Devices;
    const auth = yield* Auth;
    const limits = yield* RateLimits;
    yield* router.add(
      "POST",
      "/v1/auth/dev",
      Effect.gen(function* () {
        yield* checkAddressRateLimit(limits, "signIn");
        const request = yield* readRequest.pipe(
          Effect.mapError((error) => badRequest(error.message)),
        );
        const existing =
          request.account === undefined
            ? Option.none()
            : yield* users.findSynthetic(request.account);
        if (Option.isNone(existing) && (yield* users.count) >= maxDevUsers) {
          return HttpServerResponse.jsonUnsafe(
            { _tag: "TooManyUsers", message: `This stage already has ${maxDevUsers} users` },
            { status: 429 },
          );
        }
        const user = Option.isSome(existing)
          ? existing.value
          : yield* users.create({ displayName: request.account ?? request.displayName ?? null });
        const tokens = yield* Effect.gen(function* () {
          const device = yield* devices.create({
            userId: user.id,
            app: request.app ?? "dev",
            platform: request.platform ?? "macos",
            name: "Dev sign-in",
          });
          return yield* auth.issueSession(user.id, device.id);
          // Deleting a new user deletes its device and sessions too.
        }).pipe(
          Effect.onError(() =>
            Option.isSome(existing) ? Effect.void : users.delete(user.id).pipe(Effect.ignore),
          ),
        );
        return yield* HttpServerResponse.schemaJson(TokenPair)(tokens);
      }).pipe(
        Effect.catchTag("TooManyRequests", tooManyRequests),
        Effect.catch((error) =>
          HttpServerResponse.isHttpServerResponse(error)
            ? Effect.succeed(error)
            : Effect.die(error),
        ),
      ),
    );
  }),
);
