import * as Http from "alchemy/Http";
import { Effect, Layer, Option, Redacted, Schema } from "effect";
import { Headers, HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "./Api.ts";
import { AppleSignIn } from "./auth/Apple.ts";
import { GoogleSignIn } from "./auth/Google.ts";
import { Auth } from "./auth/Auth.ts";
import { ProviderSignIn, type VerifiedIdentity } from "./auth/ProviderSignIn.ts";
import { DevSignInRoute } from "./auth/DevSignIn.ts";
import {
  Authorization,
  CurrentSession,
  type DeviceInfo,
  Me,
  MeIdentity,
  Unauthorized,
} from "./auth/AuthApi.ts";
import { AccessTokens } from "./auth/Tokens.ts";
import { Identities } from "./core/Identities.ts";
import {
  HealthBatchNotFound,
  HealthBatchTooLarge,
  maxHealthBatchBytes,
} from "./health/HealthBatches.ts";
import { UploadSizeLimit } from "./health/HealthApi.ts";
import {
  HealthBatchFiles,
  HealthBatchQueue,
  healthBatchKey,
  healthBatchPrefix,
} from "./health/HealthIngestion.ts";
import { Users } from "./core/Users.ts";
import { Deployment } from "./Deployment.ts";
import { Status } from "./Status.ts";
import { sessionExpiresHeader } from "./store/LiveNotices.ts";
import { UserStores } from "./store/UserStores.ts";
import {
  InvalidPartUrl,
  PartUrls,
  parseRange,
  SnapshotParts,
  toManifest,
} from "./sync/SnapshotParts.ts";
import { SnapshotGone, SnapshotNotReady } from "./sync/SyncApi.ts";
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
    const apple = yield* AppleSignIn;
    const google = yield* GoogleSignIn;
    const providerSignIn = yield* ProviderSignIn;
    const signIn = (identity: VerifiedIdentity, device: typeof DeviceInfo.Type) =>
      providerSignIn
        .signIn(identity, { app: device.app, platform: device.platform, name: device.name ?? null })
        .pipe(Effect.orDie);
    return handlers
      .handle("refresh", ({ payload }) =>
        auth.refresh(payload.refreshToken).pipe(Effect.catchTag("SqlError", Effect.die)),
      )
      .handle("apple", ({ payload }) =>
        apple
          .verify(payload.identityToken, payload.nonce, payload.fullName)
          .pipe(Effect.flatMap((identity) => signIn(identity, payload.device))),
      )
      .handle("google", ({ payload }) =>
        google
          .verify(payload.idToken, payload.nonce)
          .pipe(Effect.flatMap((identity) => signIn(identity, payload.device))),
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
    const stores = yield* UserStores;
    return handlers
      .handle("me", () =>
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
      )
      .handle("deleteMe", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          // The store first: if anything fails, the account is still there to delete again,
          // and after it nothing can be written back.
          yield* stores.forUser(userId).deleteAll();
          // Per request: in the Worker it's built from each request's runtime context.
          yield* (yield* HealthBatchFiles).deletePrefix(healthBatchPrefix(userId));
          // Cascades to identities, devices, sessions (so refresh tokens stop working) and
          // connections.
          yield* users.delete(userId).pipe(Effect.orDie);
        }),
      );
  }),
);

export const SyncHandlers = HttpApiBuilder.group(
  Api,
  "sync",
  Effect.fn(function* (handlers) {
    const stores = yield* UserStores;
    const partUrls = yield* PartUrls;
    // The store comes from the session, never from the request (`docs/SYNC.md`).
    const sessionStore = CurrentSession.use((session) =>
      Effect.succeed(stores.forUser(session.userId)),
    );
    // Part URLs go to the host the client used, with its scheme (http for `alchemy dev`).
    const origin = HttpServerRequest.HttpServerRequest.use((request) =>
      Effect.sync(() => {
        try {
          return new URL(request.originalUrl).origin;
        } catch {
          return `https://${request.headers["host"] ?? "api.lil.tech"}`;
        }
      }),
    );
    return handlers
      .handle("changes", ({ query }) =>
        sessionStore.pipe(Effect.flatMap((store) => store.readChanges(query.after, query.limit))),
      )
      .handle("snapshot", () =>
        Effect.gen(function* () {
          const { epoch, snapshot } = yield* (yield* sessionStore).bootstrap();
          if (snapshot !== null) {
            return { epoch, snapshot: yield* toManifest(snapshot, yield* origin, partUrls) };
          }
          // A store's first epoch starts empty, so its whole log is the data. A later epoch's
          // data came from a migration or restore, which writes its snapshot first.
          if (epoch > 1) return yield* new SnapshotNotReady({ retryAfterSeconds: 60 });
          return { epoch };
        }),
      )
      .handle("snapshotById", ({ params }) =>
        Effect.gen(function* () {
          const snapshot = yield* (yield* sessionStore).snapshot(params.id);
          if (snapshot === null) return yield* new SnapshotGone({ id: params.id });
          return yield* toManifest(snapshot, yield* origin, partUrls);
        }),
      );
  }),
);

export const UploadSizeLimitLayer = Layer.succeed(
  UploadSizeLimit,
  UploadSizeLimit.of((httpEffect) =>
    Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest;
      if (Number(request.headers["content-length"] ?? 0) > maxHealthBatchBytes) {
        return yield* new HealthBatchTooLarge({ maxBytes: maxHealthBatchBytes });
      }
      return yield* httpEffect;
    }),
  ),
);

export const HealthHandlers = HttpApiBuilder.group(
  Api,
  "health",
  Effect.fn(function* (handlers) {
    const stores = yield* UserStores;
    return handlers
      .handle("uploadBatch", ({ params, payload }) =>
        Effect.gen(function* () {
          const { userId, deviceId } = yield* CurrentSession;
          // Per request: in the Worker they're built from each request's runtime context.
          const files = yield* HealthBatchFiles;
          const queue = yield* HealthBatchQueue;
          if (payload.byteLength > maxHealthBatchBytes) {
            return yield* new HealthBatchTooLarge({ maxBytes: maxHealthBatchBytes });
          }
          const store = stores.forUser(userId);
          const known = yield* store.healthBatch(params.id);
          if (known !== null) return known;
          // The file and the message come before the status, so a batch recorded as queued is
          // always really queued. A failure in between leaves no status, and the client retries.
          yield* files.put(healthBatchKey(userId, params.id), payload);
          yield* queue.send({ userId, batchId: params.id, deviceId });
          return yield* store
            .receiveHealthBatch(params.id)
            .pipe(
              Effect.catchTag("AccountDeleted", () =>
                Effect.fail(new Unauthorized({ message: "The user no longer exists" })),
              ),
            );
        }),
      )
      .handle("batch", ({ params }) =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          const batch = yield* stores.forUser(userId).healthBatch(params.id);
          if (batch === null) return yield* new HealthBatchNotFound({ id: params.id });
          return batch;
        }),
      );
  }),
);

/**
 * `GET /v1/sync/parts/<token>`: streams a snapshot part from a signed URL in a manifest. Needs no
 * `Authorization` header, so background downloads work; the token is the authorization. Left
 * out of the OpenAPI spec, since clients only follow manifest URLs.
 */
export const SnapshotPartRoute = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const partUrls = yield* PartUrls;
    yield* router.add(
      "GET",
      "/v1/sync/parts",
      Effect.gen(function* () {
        const { token } = yield* HttpServerRequest.schemaSearchParams(
          Schema.Struct({ token: Schema.String }),
        ).pipe(Effect.mapError((error) => new InvalidPartUrl({ message: error.message })));
        const key = yield* partUrls.verify(token);
        const request = yield* HttpServerRequest.HttpServerRequest;
        const range = parseRange(request.headers["range"]);
        const part = yield* (yield* SnapshotParts).open(key, range);
        if (Option.isNone(part)) {
          return HttpServerResponse.jsonUnsafe({ _tag: "NotFound" }, { status: 404 });
        }
        const { body, size, etag } = part.value;
        const headers = {
          "content-type": "application/gzip",
          "accept-ranges": "bytes",
          etag,
          "cache-control": "private, max-age=900",
        };
        // Resuming an interrupted download asks for the rest of the part.
        if (range !== undefined) {
          if (part.value.range === undefined) {
            yield* Effect.promise(() => body.cancel());
            return HttpServerResponse.empty({
              status: 416,
              headers: { "content-range": `bytes */${size}` },
            });
          }
          const { offset, length } = part.value.range;
          return HttpServerResponse.raw(body, {
            status: 206,
            headers: {
              ...headers,
              "content-length": String(length),
              "content-range": `bytes ${offset}-${offset + length - 1}/${size}`,
            },
          });
        }
        return HttpServerResponse.raw(body, {
          headers: { ...headers, "content-length": String(size) },
        });
      }).pipe(
        Effect.catchTag("InvalidPartUrl", () =>
          Effect.succeed(
            HttpServerResponse.jsonUnsafe(
              { _tag: "InvalidPartUrl", message: "The part URL is invalid or expired" },
              { status: 401 },
            ),
          ),
        ),
        Effect.orDie,
      ),
    );
  }),
);

/**
 * `GET /v1/sync/live`: a WebSocket of live sync notices, handed to the user's store
 * (`docs/SYNC.md`). Authenticated with the access token in the `Authorization` header like other
 * requests; the store closes the socket when that token expires. Left out of the OpenAPI spec,
 * which can't describe WebSockets.
 */
export const LiveRoute = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const accessTokens = yield* AccessTokens;
    const stores = yield* UserStores;
    yield* router.add(
      "GET",
      "/v1/sync/live",
      Effect.gen(function* () {
        const request = yield* HttpServerRequest.HttpServerRequest;
        const token = /^Bearer (.+)$/i.exec(request.headers["authorization"] ?? "")?.[1];
        const session =
          token === undefined
            ? Option.none()
            : yield* accessTokens.verifyWithExpiry(token).pipe(Effect.option);
        if (Option.isNone(session)) {
          return yield* HttpServerResponse.schemaJson(Unauthorized)(
            new Unauthorized({ message: "Missing, invalid or expired access token" }),
            { status: 401 },
          ).pipe(Effect.orDie);
        }
        if (request.headers["upgrade"]?.toLowerCase() !== "websocket") {
          return HttpServerResponse.jsonUnsafe(
            { _tag: "UpgradeRequired", message: "Connect with a WebSocket" },
            { status: 426 },
          );
        }
        // The store trusts this header: only the Worker can reach it, and it's set here.
        return yield* stores.live(
          session.value.claims.userId,
          request.modify({
            headers: Headers.set(
              request.headers,
              sessionExpiresHeader,
              String(session.value.expiresAt),
            ),
          }),
        );
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
 * Workers have no file system. Needs `Deployment`, `SessionKey`, `AppleKeys`, `GoogleKeys`,
 * `GoogleClients`, the core repositories and `UserStores`, and `HealthBatchFiles`,
 * `HealthBatchQueue` and `SnapshotParts` per request.
 */
export const WorkerHttpLayer = Layer.mergeAll(
  HttpApiBuilder.layer(Api),
  OpenApiRoute,
  DevSignInRoute,
  SnapshotPartRoute,
  LiveRoute,
).pipe(
  Layer.provide([SystemHandlers, AuthHandlers, MeHandlers, SyncHandlers, HealthHandlers]),
  Layer.provide([AuthorizationLayer, UploadSizeLimitLayer]),
  Layer.provide([AppleSignIn.layer, GoogleSignIn.layer, ProviderSignIn.layer]),
  Layer.provide([Auth.layer, PartUrls.layer]),
  Layer.provide(AccessTokens.layer),
  Layer.provide(Http.Platform),
);
