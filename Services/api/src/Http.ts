import * as Http from "alchemy/Http";
import { Clock, Effect, Layer, Option, Redacted, Schedule, Schema } from "effect";
import { Headers, HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "./Api.ts";
import { AppleSignIn, appleWebServicesId } from "./auth/Apple.ts";
import { GoogleSignIn } from "./auth/Google.ts";
import { Auth } from "./auth/Auth.ts";
import { ProviderSignIn, type VerifiedIdentity } from "./auth/ProviderSignIn.ts";
import { AppleTokens, revokeAppleTokens } from "./auth/AppleTokens.ts";
import { appleWebCallbackPath, AppleWebCallbackRoute } from "./auth/AppleWebSignIn.ts";
import { DevSignInRoute } from "./auth/DevSignIn.ts";
import {
  Authorization,
  ConsentOutdated,
  CurrentSession,
  HealthConsent,
  type DeviceInfo,
  Me,
  MeDevice,
  MeIdentity,
  Unauthorized,
} from "./auth/AuthApi.ts";
import { AccessTokens } from "./auth/Tokens.ts";
import {
  Consents,
  type GivenConsent,
  healthConsentPolicyVersion,
  isCurrentHealthConsent,
} from "./core/Consents.ts";
import { AppleTokenRevocations } from "./core/AppleTokenRevocations.ts";
import { retireDevice } from "./core/DeviceCleanup.ts";
import { Devices } from "./core/Devices.ts";
import { Identities } from "./core/Identities.ts";
import {
  ConsentRequired,
  HealthBatchNotFound,
  HealthBatchTooLarge,
  maxHealthBatchBytes,
} from "./health/HealthBatches.ts";
import { BlobUploadSizeLimit, UploadSizeLimit } from "./health/HealthApi.ts";
import {
  HealthBlobFiles,
  healthBlobDownloadPath,
  HealthBlobHashMismatch,
  healthBlobKey,
  HealthBlobNotFound,
  healthBlobPrefix,
  HealthBlobTooLarge,
  sha256Hex,
} from "./health/HealthBlobs.ts";
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
  type OpenedPart,
  type PartRange,
  partUrlLifetimeMs,
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
    const appleTokens = yield* AppleTokens;
    const identities = yield* Identities;
    const google = yield* GoogleSignIn;
    const providerSignIn = yield* ProviderSignIn;
    const devices = yield* Devices;
    const stores = yield* UserStores;
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
        Effect.gen(function* () {
          const identity = yield* apple.verify(
            payload.identityToken,
            payload.nonce,
            payload.fullName,
          );
          const tokens = yield* signIn(identity, payload.device);
          // Only once signed in, so the identity exists, and it never fails the sign-in.
          if (payload.authorizationCode !== undefined) {
            // The web sign-in's code also needs its `redirect_uri`: this API's callback.
            const redirectUri =
              identity.clientId === appleWebServicesId
                ? `${yield* origin}${appleWebCallbackPath}`
                : undefined;
            const refreshToken = yield* appleTokens.exchange(payload.authorizationCode, {
              clientId: identity.clientId,
              subject: identity.subject,
              ...(redirectUri === undefined ? {} : { redirectUri }),
            });
            if (Option.isSome(refreshToken)) {
              yield* identities
                .saveAppleToken(identity.subject, refreshToken.value, identity.clientId)
                .pipe(
                  Effect.catchCause((cause) =>
                    Effect.logWarning("Saving Apple's refresh token failed", cause),
                  ),
                );
            }
          }
          return tokens;
        }),
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
          // Signed out for good (its last session): its device-scoped records go too, so a stale
          // statistics source doesn't linger (`docs/SYNC.md`). Retired before the device row
          // goes, so if retiring fails the row is left for a later cleanup (851-2620).
          // Best-effort: the Mac also ignores sources that stopped reporting.
          if (!(yield* devices.hasSessions(session.deviceId))) {
            yield* retireDevice(
              session.userId,
              session.deviceId,
              devices.deleteIfSignedOut(session.deviceId),
            ).pipe(Effect.provideService(UserStores, stores));
          }
        }).pipe(Effect.orDie),
      );
  }),
);

/** An access token that outlived its account (deleted within the last 15 minutes). */
const userGone = new Unauthorized({ message: "The user no longer exists" });

const healthConsent = (given: Option.Option<GivenConsent>) =>
  new HealthConsent({
    required: healthConsentPolicyVersion,
    given: Option.getOrNull(given),
    current: isCurrentHealthConsent(given),
  });

export const MeHandlers = HttpApiBuilder.group(
  Api,
  "me",
  Effect.fn(function* (handlers) {
    const users = yield* Users;
    const identities = yield* Identities;
    const devices = yield* Devices;
    const stores = yield* UserStores;
    const consents = yield* Consents;
    const appleTokens = yield* AppleTokens;
    const appleRevocations = yield* AppleTokenRevocations;
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
      .handle("healthConsent", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          return healthConsent(yield* consents.current(userId, "health").pipe(Effect.orDie));
        }),
      )
      .handle("giveHealthConsent", ({ payload }) =>
        Effect.gen(function* () {
          // Consent counts only for the policy the user was shown, so an app showing an older
          // one is told to show the current one.
          if (payload.policyVersion !== healthConsentPolicyVersion) {
            return yield* new ConsentOutdated({ required: healthConsentPolicyVersion });
          }
          const { userId } = yield* CurrentSession;
          const given = yield* consents
            .grant(userId, "health", payload.policyVersion)
            .pipe(Effect.orDie);
          return healthConsent(Option.some(given));
        }),
      )
      .handle("withdrawHealthConsent", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          yield* consents.withdraw(userId, "health").pipe(Effect.orDie);
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
          const blobs = yield* HealthBlobFiles;
          // A failure here would leave an account that can't store data, so these steps are
          // retried, and if they still fail the app is told to try again, which finishes it.
          const revoking = yield* Effect.gen(function* () {
            yield* files.deletePrefix(healthBatchPrefix(userId));
            yield* blobs.deletePrefix(healthBlobPrefix(userId));
            // Their tokens are queued for revoking as they're deleted (`AppleTokenRevocations`).
            const identityIds = (yield* identities.listForUser(userId)).map(
              (identity) => identity.id,
            );
            // Cascades to identities, devices, sessions (so refresh tokens stop working) and
            // connections.
            yield* users.delete(userId);
            return identityIds;
          }).pipe(
            Effect.retry({ schedule: Schedule.exponential("200 millis"), times: 3 }),
            Effect.mapError(
              () =>
                new UserStoreUnavailable({
                  message: "Deleting the account didn't finish; try again",
                }),
            ),
          );
          // Revoked now if Apple answers, and otherwise by the daily cleanup. The account is
          // already gone, so this never fails the request.
          yield* appleRevocations.find(revoking).pipe(
            Effect.flatMap(revokeAppleTokens),
            Effect.provideService(AppleTokens, appleTokens),
            Effect.provideService(AppleTokenRevocations, appleRevocations),
            Effect.catchCause((cause) => Effect.logWarning("Revoking Apple tokens failed", cause)),
          );
        }),
      );
  }),
);

// Download URLs go to the host the client used, with its scheme (http for `alchemy dev`).
const origin = HttpServerRequest.HttpServerRequest.use((request) =>
  Effect.sync(() => {
    try {
      return new URL(request.originalUrl).origin;
    } catch {
      return `https://${request.headers["host"] ?? "api.lil.tech"}`;
    }
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

export const BlobUploadSizeLimitLayer = Layer.succeed(
  BlobUploadSizeLimit,
  BlobUploadSizeLimit.of((httpEffect) =>
    Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest;
      if (Number(request.headers["content-length"] ?? 0) > maxHealthBatchBytes) {
        return yield* new HealthBlobTooLarge({ maxBytes: maxHealthBatchBytes });
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
    const consents = yield* Consents;
    const partUrls = yield* PartUrls;
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
          const [known, consent] = yield* Effect.all(
            [
              // Fails with `StorageFull` for a new batch once the store is over its quota.
              store.checkHealthBatchUpload(params.id),
              consents.current(userId, "health").pipe(Effect.orDie),
            ],
            { concurrency: "unbounded" },
          );
          if (known !== null) return known;
          // New Health data is only taken with consent to the current policy (GDPR Article 9).
          // After the known-batch check, so a deleted account still gets a 401, and a retried
          // upload from before a withdrawal still gets its status.
          if (!isCurrentHealthConsent(consent)) {
            return yield* new ConsentRequired({ required: healthConsentPolicyVersion });
          }
          // The file and the message come before the status, so a batch recorded as queued is
          // always really queued. A failure in between leaves no status, and the client retries.
          yield* files.put(healthBatchKey(userId, params.id), payload);
          yield* queue.send({ userId, batchId: params.id, deviceId });
          return yield* store.receiveHealthBatch(params.id);
          // Checked first thing (reading the batch's status), before anything reaches R2.
        }).pipe(Effect.catchTag("AccountDeleted", () => Effect.fail(userGone))),
      )
      .handle("uploadBlob", ({ params, payload }) =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          // Per request: in the Worker it's built from each request's runtime context.
          const blobs = yield* HealthBlobFiles;
          if (payload.byteLength > maxHealthBatchBytes) {
            return yield* new HealthBlobTooLarge({ maxBytes: maxHealthBatchBytes });
          }
          const store = stores.forUser(userId);
          const [known, consent] = yield* Effect.all(
            [
              // Fails with `StorageFull` for a new blob once the account is over its quota.
              store.checkHealthBlobUpload(params.sha256),
              consents.current(userId, "health").pipe(Effect.orDie),
            ],
            { concurrency: "unbounded" },
          );
          if (known !== null) return { sha256: params.sha256, size: known };
          if (!isCurrentHealthConsent(consent)) {
            return yield* new ConsentRequired({ required: healthConsentPolicyVersion });
          }
          // Hashed after the cheaper checks: a deleted account still gets a 401, and refused or
          // repeated uploads don't pay for it.
          const actual = yield* sha256Hex(payload);
          if (actual !== params.sha256) {
            return yield* new HealthBlobHashMismatch({ sha256: params.sha256, actual });
          }
          // R2 first, so a recorded blob is always there. The same hash is the same bytes, so
          // writing it again after a failure in between is harmless.
          const key = healthBlobKey(userId, params.sha256);
          yield* blobs.put(key, payload);
          yield* store
            .recordHealthBlob(params.sha256, payload.byteLength, healthBlobPrefix(userId))
            .pipe(
              // The account was deleted meanwhile, after its blobs were: this one goes too.
              Effect.tapError((error) =>
                error._tag === "AccountDeleted" ? blobs.delete(key) : Effect.void,
              ),
            );
          return { sha256: params.sha256, size: payload.byteLength };
        }).pipe(Effect.catchTag("AccountDeleted", () => Effect.fail(userGone))),
      )
      .handle("blob", ({ params }) =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          // The key comes from the session, so only the owner's blobs can be reached.
          const size = yield* stores.forUser(userId).healthBlobSize(params.sha256);
          if (size === null) return yield* new HealthBlobNotFound({ sha256: params.sha256 });
          const token = yield* partUrls.sign(healthBlobKey(userId, params.sha256));
          return {
            url: `${yield* origin}${healthBlobDownloadPath}?token=${token}`,
            // A little before the token's own expiry, which is in whole seconds.
            expiresAt: (yield* Clock.currentTimeMillis) + partUrlLifetimeMs - 1000,
          };
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
 * A `GET` route that streams an R2 object from a signed URL, with `Range` support. Needs no
 * `Authorization` header, so background downloads work; the token is the authorization, and it
 * only grants keys under `prefix`. Left out of the OpenAPI spec, since clients only follow URLs
 * the API gave them.
 */
const signedDownloadRoute = <R>(options: {
  readonly path: `/${string}`;
  readonly prefix: string;
  readonly contentType: string;
  readonly open: (
    key: string,
    range: PartRange | undefined,
  ) => Effect.Effect<Option.Option<OpenedPart>, never, R>;
}) =>
  HttpRouter.use((router) =>
    Effect.gen(function* () {
      const partUrls = yield* PartUrls;
      yield* router.add(
        "GET",
        options.path,
        Effect.gen(function* () {
          const { token } = yield* HttpServerRequest.schemaSearchParams(
            Schema.Struct({ token: Schema.String }),
          ).pipe(Effect.mapError((error) => new InvalidPartUrl({ message: error.message })));
          const key = yield* partUrls.verify(token, options.prefix);
          const request = yield* HttpServerRequest.HttpServerRequest;
          const range = parseRange(request.headers["range"]);
          const part = yield* options.open(key, range);
          if (Option.isNone(part)) {
            return HttpServerResponse.jsonUnsafe({ _tag: "NotFound" }, { status: 404 });
          }
          const { body, size, etag } = part.value;
          const headers = {
            "content-type": options.contentType,
            "accept-ranges": "bytes",
            etag,
            "cache-control": "private, max-age=900",
          };
          // Resuming an interrupted download asks for the rest of the file.
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
                { _tag: "InvalidPartUrl", message: "The URL is invalid or expired" },
                { status: 401 },
              ),
            ),
          ),
          Effect.orDie,
        ),
      );
    }),
  );

/** `GET /v1/sync/parts?token=…`: a snapshot part, from a signed URL in a manifest. */
export const SnapshotPartRoute = signedDownloadRoute({
  path: "/v1/sync/parts",
  prefix: "snapshots/",
  contentType: "application/gzip",
  open: (key, range) => SnapshotParts.use((parts) => parts.open(key, range)),
});

/** `GET /v1/health/blob-downloads?token=…`: a health blob, from `GET /v1/health/blobs/{sha256}`. */
export const HealthBlobDownloadRoute = signedDownloadRoute({
  path: healthBlobDownloadPath,
  prefix: "health-blobs/",
  contentType: "application/octet-stream",
  open: (key, range) => HealthBlobFiles.use((files) => files.open(key, range)),
});

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
 * Workers have no file system. Needs `Deployment`, `SessionKey`, `AppleKeys`, `AppleTokens`, `GoogleKeys`,
 * `GoogleClients`, the core repositories, `UserStores` and `RateLimits`, and `HealthBatchFiles`,
 * `HealthBatchQueue` and `SnapshotParts` per request.
 */
export const WorkerHttpLayer = Layer.mergeAll(
  HttpApiBuilder.layer(Api),
  OpenApiRoute,
  DevSignInRoute,
  AppleWebCallbackRoute,
  SnapshotPartRoute,
  HealthBlobDownloadRoute,
  LiveRoute,
).pipe(
  Layer.provide([SystemHandlers, AuthHandlers, MeHandlers, SyncHandlers, HealthHandlers]),
  Layer.provide([
    AuthorizationLayer,
    AddressRateLimitLayer,
    UploadSizeLimitLayer,
    BlobUploadSizeLimitLayer,
  ]),
  Layer.provide([AppleSignIn.layer, GoogleSignIn.layer, ProviderSignIn.layer]),
  Layer.provide([Auth.layer, PartUrls.layer]),
  Layer.provide(AccessTokens.layer),
  Layer.provide(Http.Platform),
);
