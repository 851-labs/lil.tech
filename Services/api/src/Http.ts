import * as Http from "alchemy/Http";
import { Clock, Effect, Layer, Option, Redacted, Schedule, Schema } from "effect";
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
  MeDevice,
  MeIdentity,
  Unauthorized,
} from "./auth/AuthApi.ts";
import { AccessTokens } from "./auth/Tokens.ts";
import { Devices } from "./core/Devices.ts";
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
import {
  checkAddressRateLimit,
  RateLimits,
  AddressRateLimit,
  tooManyRequests,
} from "./RateLimits.ts";
import { Status } from "./Status.ts";
import { sessionExpiresHeader } from "./store/LiveNotices.ts";
import { UserStores, UserStoreUnavailable } from "./store/UserStores.ts";
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

/**
 * Verifies the bearer access token, then counts the request against the user's rate limit. Access
 * tokens are stateless, so this never hits the database.
 *
 * Signing out isn't counted: the app doesn't retry it, and a refused sign-out would leave the
 * device's refresh token working.
 */
export const AuthorizationLayer = Layer.effect(
  Authorization,
  Effect.gen(function* () {
    const accessTokens = yield* AccessTokens;
    const limits = yield* RateLimits;
    return Authorization.of({
      bearer: Effect.fn(function* (httpEffect, { credential, endpoint }) {
        const claims = yield* accessTokens
          .verify(Redacted.value(credential))
          .pipe(
            Effect.mapError(
              () => new Unauthorized({ message: "Missing, invalid or expired access token" }),
            ),
          );
        if (endpoint.identifier !== "signOut") yield* limits.check("user", claims.userId);
        return yield* Effect.provideService(httpEffect, CurrentSession, claims);
      }),
    });
  }),
);

export const AddressRateLimitLayer = Layer.effect(
  AddressRateLimit,
  Effect.gen(function* () {
    const limits = yield* RateLimits;
    return AddressRateLimit.of((httpEffect, { endpoint }) =>
      Effect.andThen(
        checkAddressRateLimit(limits, endpoint.identifier === "refresh" ? "refresh" : "signIn"),
        httpEffect,
      ),
    );
  }),
);

/**
 * The country a request came from: the Worker request's `cf.country`, which Cloudflare always
 * sets (unlike the `cf-ipcountry` header, which depends on a zone setting). Missing only in local
 * runs and tests.
 */
const requestCountry = (request: HttpServerRequest.HttpServerRequest): string | null => {
  const { cf } = request.source as { readonly cf?: { readonly country?: unknown } };
  return typeof cf?.country === "string" ? cf.country : null;
};

export const AuthHandlers = HttpApiBuilder.group(
  Api,
  "auth",
  Effect.fn(function* (handlers) {
    const auth = yield* Auth;
    const apple = yield* AppleSignIn;
    const google = yield* GoogleSignIn;
    const providerSignIn = yield* ProviderSignIn;
    const signIn = (identity: VerifiedIdentity, device: typeof DeviceInfo.Type) =>
      Effect.gen(function* () {
        return yield* providerSignIn.signIn(
          identity,
          { app: device.app, platform: device.platform, name: device.name ?? null },
          requestCountry(yield* HttpServerRequest.HttpServerRequest),
        );
      }).pipe(Effect.catchTags({ SqlError: Effect.die, SchemaError: Effect.die }));
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

/** An access token that outlived its account (deleted within the last 15 minutes). */
const userGone = new Unauthorized({ message: "The user no longer exists" });

export const MeHandlers = HttpApiBuilder.group(
  Api,
  "me",
  Effect.fn(function* (handlers) {
    const users = yield* Users;
    const identities = yield* Identities;
    const devices = yield* Devices;
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
          const [userIdentities, userDevices] = yield* Effect.all(
            [
              identities.listForUser(session.userId),
              devices.listSignedInForUser(session.userId, yield* Clock.currentTimeMillis),
            ],
            { concurrency: "unbounded" },
          ).pipe(Effect.orDie);
          return new Me({
            id: user.value.id,
            displayName: user.value.displayName,
            identities: userIdentities.map(
              (identity) => new MeIdentity({ provider: identity.provider, email: identity.email }),
            ),
            devices: userDevices.map(
              (device) =>
                new MeDevice({
                  id: device.id,
                  app: device.app,
                  platform: device.platform,
                  name: device.name,
                  createdAt: device.createdAt,
                  current: device.id === session.deviceId,
                }),
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
          const files = yield* HealthBatchFiles;
          // A failure here would leave an account that can't store data, so these steps are
          // retried, and if they still fail the app is told to try again, which finishes it.
          yield* Effect.gen(function* () {
            yield* files.deletePrefix(healthBatchPrefix(userId));
            // Cascades to identities, devices, sessions (so refresh tokens stop working) and
            // connections.
            yield* users.delete(userId);
          }).pipe(
            Effect.retry({ schedule: Schedule.exponential("200 millis"), times: 3 }),
            Effect.mapError(
              () =>
                new UserStoreUnavailable({
                  message: "Deleting the account didn't finish; try again",
                }),
            ),
          );
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
          // Fails with `StorageFull` for a new batch once the store is over its quota.
          const known = yield* store.checkHealthBatchUpload(params.id);
          if (known !== null) return known;
          // The file and the message come before the status, so a batch recorded as queued is
          // always really queued. A failure in between leaves no status, and the client retries.
          yield* files.put(healthBatchKey(userId, params.id), payload);
          yield* queue.send({ userId, batchId: params.id, deviceId });
          return yield* store.receiveHealthBatch(params.id);
          // Checked first thing (reading the batch's status), before anything reaches R2.
        }).pipe(Effect.catchTag("AccountDeleted", () => Effect.fail(userGone))),
      )
      .handle("batch", ({ params }) =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          const batch = yield* stores.forUser(userId).healthBatch(params.id);
          if (batch === null) return yield* new HealthBatchNotFound({ id: params.id });
          return batch;
        }).pipe(Effect.catchTag("AccountDeleted", () => Effect.fail(userGone))),
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
    const limits = yield* RateLimits;
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
        yield* limits.check("user", session.value.claims.userId);
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
      }).pipe(Effect.catchTag("TooManyRequests", tooManyRequests)),
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
 * `GoogleClients`, the core repositories, `UserStores` and `RateLimits`, and `HealthBatchFiles`,
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
  Layer.provide([AuthorizationLayer, AddressRateLimitLayer, UploadSizeLimitLayer]),
  Layer.provide([AppleSignIn.layer, GoogleSignIn.layer, ProviderSignIn.layer]),
  Layer.provide([Auth.layer, PartUrls.layer]),
  Layer.provide(AccessTokens.layer),
  Layer.provide(Http.Platform),
);
