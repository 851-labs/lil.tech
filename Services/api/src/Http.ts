import * as Http from "alchemy/Http";
import { Clock, Effect, Layer, Option, Redacted, Schedule, Schema } from "effect";
import { Headers, HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "./Api.ts";
import { type AppleIdentity, AppleSignIn, appleWebServicesId } from "./auth/Apple.ts";
import { GoogleSignIn } from "./auth/Google.ts";
import { Auth } from "./auth/Auth.ts";
import { ProviderSignIn, type VerifiedIdentity } from "./auth/ProviderSignIn.ts";
import { AppleTokens, revokeAppleTokens } from "./auth/AppleTokens.ts";
import { appleWebCallbackPath, AppleWebCallbackRoute } from "./auth/AppleWebSignIn.ts";
import { DevSignInRoute } from "./auth/DevSignIn.ts";
import { AgentTokens } from "./oauth/AgentTokens.ts";
import { AgentGrants } from "./core/AgentGrants.ts";
import { agentAccessLogPolicy } from "./store/AgentAccessLog.ts";
import { AgentMcpRoutes } from "./mcp/McpRoutes.ts";
import { AgentsHandlers } from "./oauth/AgentsHandlers.ts";
import { AgentHostsMiddleware, AgentOAuthRoutes } from "./oauth/OAuthRoutes.ts";
import {
  Authorization,
  ConsentOutdated,
  CurrentSession,
  DataExport,
  DataExportNotFound,
  HealthConsent,
  type DeviceInfo,
  IdentityNotFound,
  LastIdentity,
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
import { Identities, type Identity } from "./core/Identities.ts";
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
import type { Snapshot } from "./store/Snapshots.ts";
import {
  type ArchiveEntry,
  archiveSize,
  archiveStream,
  maxArchiveFiles,
} from "./sync/ExportArchive.ts";
import { Connections } from "./core/Connections.ts";
import type { UserId } from "./core/Ids.ts";
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
import { MutationRejected, SnapshotGone, SnapshotNotReady } from "./sync/SyncApi.ts";
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

/**
 * Redeems Apple's authorization code (if the app sent one) for the refresh token that deleting
 * the account revokes, and keeps it with the identity, which must exist by now. Never fails the
 * request: without it, the account just can't have its token revoked.
 */
const keepAppleToken = (
  appleTokens: AppleTokens["Service"],
  identities: Identities["Service"],
  identity: AppleIdentity,
  authorizationCode: string | undefined,
) =>
  Effect.gen(function* () {
    if (authorizationCode === undefined) return;
    // The web sign-in's code also needs its `redirect_uri`: this API's callback.
    const redirectUri =
      identity.clientId === appleWebServicesId
        ? `${yield* origin}${appleWebCallbackPath}`
        : undefined;
    const refreshToken = yield* appleTokens.exchange(authorizationCode, {
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
  });

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
          // Only once signed in, so the identity exists.
          yield* keepAppleToken(appleTokens, identities, identity, payload.authorizationCode);
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

/** Where export download URLs point (`ExportDownloadRoute`). */
export const exportDownloadPath = "/v1/exports/download";

/**
 * What an export download URL grants: the user's export asked for at `requestedAt`, from
 * `snapshotId` (`-` for a store that had nothing).
 */
const exportKey = (userId: UserId, requestedAt: number, snapshotId: string | null) =>
  `exports/${userId}/${requestedAt}/${snapshotId ?? "-"}`;

const meIdentity = (identity: Identity) =>
  new MeIdentity({ id: identity.id, provider: identity.provider, email: identity.email });

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
    const apple = yield* AppleSignIn;
    const google = yield* GoogleSignIn;
    const providerSignIn = yield* ProviderSignIn;
    const partUrls = yield* PartUrls;
    /** An export as the app gets it: once ready, with a fresh download URL. */
    const dataExport = (
      userId: UserId,
      status: {
        readonly requestedAt: number;
        readonly ready: boolean;
        readonly snapshot: Snapshot | null;
      },
    ) =>
      Effect.gen(function* () {
        if (!status.ready) {
          return new DataExport({
            requestedAt: status.requestedAt,
            ready: false,
            url: null,
            urlExpiresAt: null,
          });
        }
        const token = yield* partUrls.sign(
          exportKey(userId, status.requestedAt, status.snapshot?.id ?? null),
        );
        return new DataExport({
          requestedAt: status.requestedAt,
          ready: true,
          url: `${yield* origin}${exportDownloadPath}?token=${token}`,
          urlExpiresAt: (yield* Clock.currentTimeMillis) + partUrlLifetimeMs - 1000,
        });
      });
    /** Links the verified identity to the signed-in user. */
    const link = (identity: VerifiedIdentity) =>
      Effect.gen(function* () {
        const { userId } = yield* CurrentSession;
        // The access token outlived its user: there's no one to link it to.
        if (Option.isNone(yield* users.findById(userId))) return yield* userGone;
        return yield* providerSignIn.link(userId, identity);
      }).pipe(Effect.catchTags({ SqlError: Effect.die, SchemaError: Effect.die }));
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
            identities: userIdentities.map(meIdentity),
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
      .handle("linkApple", ({ payload }) =>
        Effect.gen(function* () {
          const identity = yield* apple.verify(payload.identityToken, payload.nonce, undefined);
          const linked = yield* link(identity);
          yield* keepAppleToken(appleTokens, identities, identity, payload.authorizationCode);
          return meIdentity(linked);
        }),
      )
      .handle("linkGoogle", ({ payload }) =>
        Effect.gen(function* () {
          const identity = yield* google.verify(payload.idToken, payload.nonce);
          return meIdentity(yield* link(identity));
        }),
      )
      .handle("unlinkIdentity", ({ params }) =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          const result = yield* identities.deleteUnlessLast(userId, params.id).pipe(Effect.orDie);
          if (result === "last") {
            return yield* new LastIdentity({
              message: "Your only sign-in method can't be removed",
            });
          }
          if (result === "notFound") {
            return yield* new IdentityNotFound({ message: "No such sign-in method" });
          }
          // An Apple identity's token was queued for revoking as it was deleted. Revoked now if
          // Apple answers, and otherwise by the daily cleanup.
          yield* appleRevocations.find([params.id]).pipe(
            Effect.flatMap(revokeAppleTokens),
            Effect.provideService(AppleTokens, appleTokens),
            Effect.provideService(AppleTokenRevocations, appleRevocations),
            Effect.catchCause((cause) => Effect.logWarning("Revoking Apple tokens failed", cause)),
          );
        }),
      )
      .handle("requestExport", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          return yield* dataExport(userId, yield* stores.forUser(userId).requestExport());
        }).pipe(Effect.catchTag("AccountDeleted", () => Effect.fail(userGone))),
      )
      .handle("latestExport", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          const status = yield* stores.forUser(userId).exportStatus();
          if (status === null) {
            return yield* new DataExportNotFound({ message: "No export was asked for" });
          }
          return yield* dataExport(userId, status);
        }).pipe(Effect.catchTag("AccountDeleted", () => Effect.fail(userGone))),
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
          // Its sessions are gone now, so its other devices can be told to sign out (851-2666).
          // They'd find out at their next request anyway, so this never fails the request.
          yield* stores
            .forUser(userId)
            .signOutDevices()
            .pipe(
              Effect.catchCause((cause) => Effect.logWarning("Signing devices out failed", cause)),
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
      .handle("pushMutations", ({ payload }) =>
        sessionStore.pipe(
          Effect.flatMap((store) => store.pushMutations(payload.mutationId, payload.mutations)),
          Effect.catchTags({
            InvalidMutation: (error) =>
              Effect.fail(new MutationRejected({ index: error.index, message: error.message })),
            AccountDeleted: () => Effect.fail(userGone),
          }),
        ),
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

/** What an export archive says about itself. */
const exportReadme = `This is everything your lil account holds, as of the date in this folder's name.

account.json      Your account: profile, sign-in methods, devices, consents, connections and
                  connected agents.
agent-access-log.json  Every call agents you connected made to read your data: when, which agent,
                  the tool and what it asked for, never what it read. Kept 90 days.
records/          Your synced records, by kind: gzip-compressed files of JSON, one record a line.
records/manifest.json  The record files and how many records each holds.
blobs/            Large health data (e.g. ECG voltages, workout routes), named by their SHA-256,
                  which records refer to.
`;

/**
 * \`GET /v1/exports/download?token=…\`: a data export's archive, from the URL \`POST /v1/me/exports\`
 * gave. Streams a tar of the account data, the export's snapshot parts and the user's blobs
 * (\`src/sync/ExportArchive.ts\`). Left out of the OpenAPI spec, like the other signed downloads.
 */
export const ExportDownloadRoute = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const partUrls = yield* PartUrls;
    const stores = yield* UserStores;
    const users = yield* Users;
    const identities = yield* Identities;
    const devices = yield* Devices;
    const consents = yield* Consents;
    const connections = yield* Connections;
    const agentGrants = yield* AgentGrants;
    yield* router.add(
      "GET",
      exportDownloadPath,
      Effect.gen(function* () {
        const { token } = yield* HttpServerRequest.schemaSearchParams(
          Schema.Struct({ token: Schema.String }),
        ).pipe(Effect.mapError((error) => new InvalidPartUrl({ message: error.message })));
        const key = yield* partUrls.verify(token, "exports/");
        const [, user = "", requestedAt = "", snapshotId = "-"] = key.split("/");
        const userId = user as UserId;
        const gone = HttpServerResponse.jsonUnsafe(
          { _tag: "DataExportGone", message: "Ask for the export again" },
          { status: 410 },
        );
        const found = yield* users.findById(userId);
        if (Option.isNone(found)) return gone;
        // A replaced snapshot stays a week (`snapshotPolicy.replacedRetention`), far longer than
        // the URL works.
        const snapshot =
          snapshotId === "-" ? null : yield* stores.forUser(userId).snapshot(snapshotId);
        if (snapshotId !== "-" && snapshot === null) return gone;
        const [
          userIdentities,
          userDevices,
          healthConsent,
          agentsConsent,
          userConnections,
          userAgents,
          accessLog,
        ] = yield* Effect.all(
          [
            identities.listForUser(userId),
            devices.listForUser(userId),
            consents.current(userId, "health"),
            consents.current(userId, "agents:health"),
            connections.listForUser(userId),
            agentGrants.listForUser(userId),
            // All of it, in one call: it's at most `agentAccessLogPolicy.maxRows` short rows.
            stores.forUser(userId).agentAccessLog(null, agentAccessLogPolicy.maxRows),
          ],
          { concurrency: "unbounded" },
        );
        const now = yield* Clock.currentTimeMillis;
        const json = (value: unknown) => new TextEncoder().encode(JSON.stringify(value, null, 2));
        const account = json({
          exportedAt: new Date(now).toISOString(),
          user: found.value,
          identities: userIdentities.map(({ provider, email, emailVerified, createdAt }) => ({
            provider,
            email,
            emailVerified,
            createdAt,
          })),
          devices: userDevices.map(({ app, platform, name, createdAt, lastSeenAt }) => ({
            app,
            platform,
            name,
            createdAt,
            lastSeenAt,
          })),
          consents: {
            health: Option.getOrNull(healthConsent),
            "agents:health": Option.getOrNull(agentsConsent),
          },
          // Without credentials, which are only good to the server.
          connections: userConnections.map(
            ({ kind, accountRef, displayName, scopes, status, createdAt, updatedAt }) => ({
              kind,
              accountRef,
              displayName,
              scopes,
              status,
              createdAt,
              updatedAt,
            }),
          ),
          // Without tokens, which are only stored as hashes anyway.
          agents: userAgents.map(
            ({
              id,
              clientName,
              clientDomain,
              redirectHost,
              scopes,
              resource,
              createdAt,
              lastUsedAt,
            }) => ({
              id,
              name: clientName,
              domain: clientDomain,
              redirectHost,
              scopes,
              resource,
              connectedAt: createdAt,
              lastUsedAt,
            }),
          ),
        });
        // Oldest first, as a log reads.
        const agentAccessLog = json(
          accessLog
            .toReversed()
            .map(({ at, grantId, clientName, tool, types, range, date, outcome, rows }) => ({
              at: new Date(at).toISOString(),
              agentId: grantId,
              agentName: clientName,
              tool,
              types,
              range,
              date,
              outcome,
              rows,
            })),
        );
        const folder = `lil-export-${new Date(Number(requestedAt)).toISOString().slice(0, 10)}`;
        const parts = yield* SnapshotParts;
        const records = (snapshot?.entities ?? []).flatMap(({ entity, parts: files }) =>
          files.map((part, index) => ({
            entity,
            part,
            name: `records/${entity}/${String(index + 1).padStart(5, "0")}.ndjson.gz`,
          })),
        );
        const manifest = json({
          snapshot:
            snapshot === null
              ? null
              : { seq: snapshot.seq, createdAt: new Date(snapshot.createdAt).toISOString() },
          files: records.map(({ entity, part, name }) => ({
            entity,
            file: name,
            records: part.records,
            sha256: part.sha256,
          })),
        });
        // Per request: in the Worker they're built from each request's runtime context.
        const blobFiles = yield* HealthBlobFiles;
        const blobs = yield* blobFiles.list(healthBlobPrefix(userId));
        if (records.length + blobs.length > maxArchiveFiles) {
          return HttpServerResponse.jsonUnsafe(
            {
              _tag: "DataExportTooLarge",
              message: "The account holds too many files for one archive",
            },
            { status: 507 },
          );
        }
        const open =
          (opened: Effect.Effect<Option.Option<{ readonly body: ReadableStream<Uint8Array> }>>) =>
          () =>
            Effect.runPromise(
              opened.pipe(Effect.map((file) => Option.getOrNull(file)?.body ?? null)),
            );
        const readme = new TextEncoder().encode(exportReadme);
        const entries: Array<ArchiveEntry> = [
          { name: `${folder}/README.txt`, size: readme.length, content: readme },
          { name: `${folder}/account.json`, size: account.length, content: account },
          {
            name: `${folder}/agent-access-log.json`,
            size: agentAccessLog.length,
            content: agentAccessLog,
          },
          { name: `${folder}/records/manifest.json`, size: manifest.length, content: manifest },
          ...records.map(({ part, name }) => ({
            name: `${folder}/${name}`,
            size: part.bytes,
            content: open(parts.open(part.key, undefined)),
          })),
          ...blobs.map((blob) => ({
            name: `${folder}/blobs/${blob.key.slice(healthBlobPrefix(userId).length)}`,
            size: blob.size,
            content: open(blobFiles.open(blob.key, undefined)),
          })),
        ];
        return HttpServerResponse.raw(archiveStream(entries, Math.floor(now / 1000)), {
          headers: {
            "content-type": "application/x-tar",
            "content-length": String(archiveSize(entries)),
            "content-disposition": `attachment; filename="${folder}.tar"`,
            "cache-control": "private, no-store",
          },
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
  ExportDownloadRoute,
  LiveRoute,
  AgentOAuthRoutes,
  AgentMcpRoutes,
  AgentHostsMiddleware,
).pipe(
  Layer.provide([
    SystemHandlers,
    AuthHandlers,
    MeHandlers,
    SyncHandlers,
    HealthHandlers,
    AgentsHandlers,
  ]),
  Layer.provide([
    AuthorizationLayer,
    AddressRateLimitLayer,
    UploadSizeLimitLayer,
    BlobUploadSizeLimitLayer,
  ]),
  Layer.provide([AppleSignIn.layer, GoogleSignIn.layer, ProviderSignIn.layer]),
  Layer.provide([Auth.layer, PartUrls.layer, AgentTokens.layer]),
  Layer.provide(AccessTokens.layer),
  Layer.provide(Http.Platform),
);
