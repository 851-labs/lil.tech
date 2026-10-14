import * as Http from "alchemy/Http";
import { Effect, Layer, Option, Redacted } from "effect";
import { HttpRouter, HttpServerResponse } from "effect/http";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "./Api.ts";
import { Auth } from "./auth/Auth.ts";
import { Authorization, CurrentSession, Me, MeIdentity, Unauthorized } from "./auth/AuthApi.ts";
import { AccessTokens } from "./auth/Tokens.ts";
import { Identities } from "./core/Identities.ts";
import { Users } from "./core/Users.ts";
import { Deployment } from "./Deployment.ts";
import { Status } from "./Status.ts";
import { UserStores } from "./store/UserStores.ts";
// The committed spec (see scripts/openapi.ts), so the served contract is exactly the committed one.
import openApiSpec from "../openapi.json" with { type: "json" };

export const SystemHandlers = HttpApiBuilder.group(
  Api,
  "system",
  Effect.fn(function* (handlers) {
    const status = new Status(yield* Deployment);
    return handlers.handle("status", () => Effect.succeed(status));
  }),
);

/** Verifies the bearer access token. Access tokens are stateless, so this never hits the database. */
export const AuthorizationLayer = Layer.effect(
  Authorization,
  Effect.gen(function* () {
    const accessTokens = yield* AccessTokens;
    return Authorization.of({
      bearer: Effect.fn(function* (httpEffect, { credential }) {
        const claims = yield* accessTokens
          .verify(Redacted.value(credential))
          .pipe(
            Effect.mapError(
              () => new Unauthorized({ message: "Missing, invalid or expired access token" }),
            ),
          );
        return yield* Effect.provideService(httpEffect, CurrentSession, claims);
      }),
    });
  }),
);

export const AuthHandlers = HttpApiBuilder.group(
  Api,
  "auth",
  Effect.fn(function* (handlers) {
    const auth = yield* Auth;
    return handlers
      .handle("refresh", ({ payload }) =>
        auth.refresh(payload.refreshToken).pipe(Effect.catchTag("SqlError", Effect.die)),
      )
      .handle("signOut", () =>
        Effect.gen(function* () {
          const session = yield* CurrentSession;
          yield* auth.signOut(session.sessionId);
        }).pipe(Effect.orDie),
      );
  }),
);

export const MeHandlers = HttpApiBuilder.group(
  Api,
  "me",
  Effect.fn(function* (handlers) {
    const users = yield* Users;
    const identities = yield* Identities;
    return handlers.handle("me", () =>
      Effect.gen(function* () {
        const session = yield* CurrentSession;
        const user = yield* users.findById(session.userId).pipe(Effect.orDie);
        // The access token outlived its user (deleted within the last 15 minutes).
        if (Option.isNone(user)) {
          return yield* new Unauthorized({ message: "The user no longer exists" });
        }
        const userIdentities = yield* identities.listForUser(session.userId).pipe(Effect.orDie);
        return new Me({
          id: user.value.id,
          displayName: user.value.displayName,
          identities: userIdentities.map(
            (identity) => new MeIdentity({ provider: identity.provider, email: identity.email }),
          ),
        });
      }),
    );
  }),
);

export const SyncHandlers = HttpApiBuilder.group(
  Api,
  "sync",
  Effect.fn(function* (handlers) {
    const stores = yield* UserStores;
    return handlers.handle("changes", ({ query }) =>
      Effect.gen(function* () {
        // The store comes from the session, never from the request (`docs/SYNC.md`).
        const session = yield* CurrentSession;
        return yield* stores.forUser(session.userId).readChanges(query.after, query.limit);
      }),
    );
  }),
);

const OpenApiRoute = HttpRouter.add(
  "GET",
  "/v1/openapi.json",
  HttpServerResponse.jsonUnsafe(openApiSpec),
);

/**
 * Every route of the API, with the platform services a Worker can provide: Alchemy's
 * `Http.Platform` stubs file responses and gives `HttpApiBuilder` a no-op `FileSystem`, since
 * Workers have no file system. Needs `Deployment`, `SessionKey`, the core repositories and
 * `UserStores`.
 */
export const WorkerHttpLayer = Layer.mergeAll(HttpApiBuilder.layer(Api), OpenApiRoute).pipe(
  Layer.provide([SystemHandlers, AuthHandlers, MeHandlers, SyncHandlers]),
  Layer.provide(AuthorizationLayer),
  Layer.provide(Auth.layer),
  Layer.provide(AccessTokens.layer),
  Layer.provide(Http.Platform),
);
