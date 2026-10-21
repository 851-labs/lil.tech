import { appleAppId, appleWebServicesId } from "../src/auth/Apple.ts";
import { appleWebCallback, appleWebOrigin } from "../src/auth/AppleWebSignIn.ts";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { gunzipSync } from "node:zlib";
import { assert, describe, it } from "@effect/vitest";
import * as Alchemy from "alchemy";
import { ConfigProvider, Effect, Exit, Option, Redacted, Schema } from "effect";
import { SqlClient } from "effect/sql";
import { TestClock } from "effect/testing";
import { HttpApi, HttpApiEndpoint, HttpApiGroup } from "effect/http-api";
import { Deployment, disposableBucketProps, environmentForStage } from "../src/Deployment.ts";
import { Auth } from "../src/auth/Auth.ts";
import { ingestHealthBatch } from "../src/health/HealthIngestion.ts";
import { maxDevUsers } from "../src/auth/DevSignIn.ts";
import { AccessTokens } from "../src/auth/Tokens.ts";
import { Consents, healthConsentPolicyVersion } from "../src/core/Consents.ts";
import { Devices } from "../src/core/Devices.ts";
import { Identities } from "../src/core/Identities.ts";
import type { UserId } from "../src/core/Ids.ts";
import { Users } from "../src/core/Users.ts";
import { snapshotPolicy } from "../src/store/Snapshots.ts";
import { storageQuotaBytes } from "../src/store/UserStore.ts";
import { sessionExpiresHeader } from "../src/store/LiveNotices.ts";
import { UserStores } from "../src/store/UserStores.ts";
import { PartUrls } from "../src/sync/SnapshotParts.ts";
import { makeOpenApiSpec } from "../src/OpenApiSpec.ts";
import {
  addressKey,
  type RateLimitCounter,
  type RateLimitName,
  rateLimitNamespaceId,
  RateLimits,
  rateLimits,
} from "../src/RateLimits.ts";
import { makeApiWorkerProps } from "../src/Worker.ts";
import { appleIdentityToken } from "./auth/TestApple.ts";
import { googleIdToken } from "./auth/TestGoogle.ts";
import { AppleTokens } from "../src/auth/AppleTokens.ts";
import { AppleTokenRevocations } from "../src/core/AppleTokenRevocations.ts";
import { TestAppleEndpoint, testAppleCode, testAppleRefreshToken } from "./auth/TestAppleTokens.ts";
import { batchFile, TestHealthOutbox } from "./health/TestHealthIngestion.ts";
import { TestHealthBlobBucket } from "./health/TestHealthBlobs.ts";
import { healthBlobPrefix } from "../src/health/HealthBlobs.ts";
import { maxArchiveFiles } from "../src/sync/ExportArchive.ts";
import { entities } from "../src/store/Registry.ts";
import { TestStores, testNoteMutation, writeTestSnapshot } from "./store/TestUserStores.ts";

import { type Handler, send, withApi } from "./TestApi.ts";

const committedSpec = readFileSync(new URL("../openapi.json", import.meta.url), "utf8");

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

/** A request as the Worker gets it from Cloudflare, with `cf.country` set when there's a country. */
const fromCountry = (request: Request, country: string | undefined) =>
  country === undefined ? request : Object.assign(request, { cf: { country } });

const signIn = Effect.gen(function* () {
  const user = yield* (yield* Users).create({ displayName: "Ada" });
  yield* (yield* Identities).create({
    userId: user.id,
    provider: "apple",
    subject: crypto.randomUUID(),
    email: "ada@privaterelay.appleid.com",
    emailVerified: true,
  });
  const device = yield* (yield* Devices).create({
    userId: user.id,
    app: "health-ios",
    platform: "ios",
    name: null,
  });
  const tokens = yield* (yield* Auth).issueSession(user.id, device.id);
  return { user, tokens };
});

interface MeIdentityBody {
  readonly id: string;
  readonly provider: string;
  readonly email: string | null;
}

/** The provider and email of each identity in a `GET /v1/me` body. */
const identitiesOf = (body: unknown) =>
  (body as { identities: ReadonlyArray<MeIdentityBody> }).identities.map(({ provider, email }) => ({
    provider,
    email,
  }));

const refresh = (handler: Handler, refreshToken: string) =>
  send(
    handler,
    new Request("https://api.lil.tech/v1/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    }),
  );

describe("WorkerHttpLayer", () => {
  it.live("GET /v1/status returns the deployment's environment and version", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* send(
          handler,
          new Request("https://api.staging.lil.tech/v1/status"),
        );
        assert.deepStrictEqual(response, {
          status: 200,
          body: { environment: "staging", version: "45aa829" },
        });
      }),
    ),
  );

  it.live("GET /v1/openapi.json serves the committed spec", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const response = yield* send(
            handler,
            new Request("https://api.lil.tech/v1/openapi.json"),
          );
          assert.deepStrictEqual(response, { status: 200, body: JSON.parse(committedSpec) });
        }),
      { environment: "prod", version: "1" },
    ),
  );

  it.live("unknown paths return 404", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* send(handler, new Request("https://api.lil.tech/v1/nope"));
        assert.strictEqual(response.status, 404);
      }),
    ),
  );

  it.live("GET /v1/me returns the signed-in user and their identities", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.accessToken) }),
        );
        const [device] = yield* (yield* Devices).listForUser(user.id);
        const [identity] = yield* (yield* Identities).listForUser(user.id);
        assert.deepStrictEqual(response, {
          status: 200,
          body: {
            id: user.id,
            displayName: "Ada",
            identities: [
              { id: identity?.id, provider: "apple", email: "ada@privaterelay.appleid.com" },
            ],
            devices: [
              {
                id: device?.id,
                app: "health-ios",
                platform: "ios",
                name: null,
                createdAt: device?.createdAt,
                current: true,
              },
            ],
          },
        });
      }),
    ),
  );

  it.live("GET /v1/me leaves out devices that signed out or whose sessions expired", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const auth = yield* Auth;
        const deviceRepo = yield* Devices;
        // Signed in, then out: the device row stays behind.
        const old = yield* deviceRepo.create({
          userId: user.id,
          app: "health-ios",
          platform: "ios",
          name: null,
        });
        const oldTokens = yield* auth.issueSession(user.id, old.id);
        yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/sign-out", {
            method: "POST",
            headers: bearer(oldTokens.accessToken),
          }),
        );
        // A session that's long expired.
        const stale = yield* deviceRepo.create({
          userId: user.id,
          app: "health-ios",
          platform: "ios",
          name: null,
        });
        yield* auth.issueSession(user.id, stale.id).pipe(Effect.provide(TestClock.layer()));

        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.accessToken) }),
        );
        const { devices } = response.body as { devices: Array<{ id: string; current: boolean }> };
        assert.deepStrictEqual(
          devices.map(({ current }) => current),
          [true],
        );
      }),
    ),
  );

  it.live("GET /v1/me lists every device, marking the one asking", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user } = yield* signIn;
        const mac = yield* (yield* Devices).create({
          userId: user.id,
          app: "health-mac",
          platform: "macos",
          name: "Ada's Mac",
        });
        const macTokens = yield* (yield* Auth).issueSession(user.id, mac.id);
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(macTokens.accessToken) }),
        );
        const { devices } = response.body as {
          devices: Array<{ app: string; name: string | null; current: boolean }>;
        };
        assert.deepStrictEqual(
          devices.map(({ app, name, current }) => ({ app, name, current })),
          [
            { app: "health-ios", name: null, current: false },
            { app: "health-mac", name: "Ada's Mac", current: true },
          ],
        );
      }),
    ),
  );

  it.live("GET /v1/me rejects missing, invalid and expired access tokens", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const accessTokens = yield* AccessTokens;
        // Signed under a test clock at 1970, so it expired long ago.
        const expired = yield* accessTokens
          .sign(yield* accessTokens.verify(tokens.accessToken))
          .pipe(Effect.provide(TestClock.layer()));
        const requests = [
          new Request("https://api.lil.tech/v1/me", { headers: bearer(expired.token) }),
          new Request("https://api.lil.tech/v1/me"),
          new Request("https://api.lil.tech/v1/me", { headers: bearer("nope") }),
          new Request("https://api.lil.tech/v1/me", { headers: bearer(`${tokens.accessToken}x`) }),
          // A refresh token isn't an access token.
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.refreshToken) }),
        ];
        for (const request of requests) {
          const response = yield* send(handler, request);
          assert.strictEqual(response.status, 401);
          assert.propertyVal(response.body, "_tag", "Unauthorized");
        }
      }),
    ),
  );

  it.live("GET /v1/me rejects an access token whose user was deleted", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        yield* (yield* Users).delete(user.id);
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.accessToken) }),
        );
        assert.strictEqual(response.status, 401);
      }),
    ),
  );

  it.live("POST /v1/auth/refresh rotates the refresh token", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const first = yield* refresh(handler, tokens.refreshToken);
        assert.strictEqual(first.status, 200);
        const pair = first.body as { accessToken: string; refreshToken: string };
        assert.notStrictEqual(pair.refreshToken, tokens.refreshToken);

        const me = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(pair.accessToken) }),
        );
        assert.strictEqual(me.status, 200);

        const reused = yield* refresh(handler, tokens.refreshToken);
        assert.strictEqual(reused.status, 401);
        assert.propertyVal(reused.body, "_tag", "InvalidRefreshToken");
        assert.strictEqual((yield* refresh(handler, pair.refreshToken)).status, 401);
      }),
    ),
  );

  it.live("POST /v1/auth/refresh rejects a malformed body", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/refresh", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ token: "lrt_x" }),
          }),
        );
        assert.strictEqual(response.status, 400);
      }),
    ),
  );

  it.live("POST /v1/auth/sign-out deletes the device and retires it in the store", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const [device] = yield* (yield* Devices).listForUser(user.id);
        assert.isDefined(device);
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/sign-out", {
            method: "POST",
            headers: bearer(tokens.accessToken),
          }),
        );
        assert.strictEqual(response.status, 204);
        assert.isTrue(Option.isNone(yield* (yield* Devices).findById(device.id)));
        const sql = (yield* TestStores).sqlFor(user.id);
        assert.deepStrictEqual(sql?.exec("SELECT device FROM retired_devices"), [
          { device: device.id },
        ]);
      }),
    ),
  );

  it.live("POST /v1/auth/sign-out ends the session", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const unauthenticated = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/sign-out", { method: "POST" }),
        );
        assert.strictEqual(unauthenticated.status, 401);

        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/sign-out", {
            method: "POST",
            headers: bearer(tokens.accessToken),
          }),
        );
        assert.strictEqual(response.status, 204);
        assert.strictEqual((yield* refresh(handler, tokens.refreshToken)).status, 401);
      }),
    ),
  );
});

describe("POST /v1/auth/apple", () => {
  const appleSignIn = (handler: Handler, body: unknown, country?: string) =>
    send(
      handler,
      fromCountry(
        new Request("https://api.lil.tech/v1/auth/apple", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        }),
        country,
      ),
    );
  const device = { app: "health-mac", platform: "macos" };

  it.live("signs in with an Apple identity token", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const nonce = crypto.randomUUID();
        const identityToken = yield* appleIdentityToken({ sub: "000123.http.0001", nonce });
        const response = yield* appleSignIn(handler, {
          identityToken,
          nonce,
          fullName: { givenName: "Ada", familyName: null },
          device,
        });
        assert.strictEqual(response.status, 200);
        const { accessToken } = response.body as { accessToken: string };
        const me = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(accessToken) }),
        );
        assert.propertyVal(me.body, "displayName", "Ada");
        assert.deepStrictEqual(identitiesOf(me.body), [
          { provider: "apple", email: "x7y2@privaterelay.appleid.com" },
        ]);
      }),
    ),
  );

  it.live("signs the Mac's web sign-in (the Services ID) in to the same user", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const users = yield* Users;
        const signIn = (audience?: string) =>
          Effect.gen(function* () {
            const nonce = crypto.randomUUID();
            const identityToken = yield* appleIdentityToken(
              { sub: "000123.http.0004", nonce },
              audience === undefined ? {} : { audience },
            );
            return yield* appleSignIn(handler, { identityToken, nonce, device });
          });
        assert.strictEqual((yield* signIn()).status, 200);
        assert.strictEqual((yield* signIn(appleWebServicesId)).status, 200);
        assert.strictEqual(yield* users.count, 1);
        // Another app's tokens aren't ours.
        assert.strictEqual((yield* signIn("com.example.other")).status, 401);
      }),
    ),
  );

  it.live("keeps Apple's refresh token, for the client the sign-in was for", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const sql = yield* SqlClient.SqlClient;
        const signIn = (sub: string, audience: string) =>
          Effect.gen(function* () {
            const nonce = crypto.randomUUID();
            const identityToken = yield* appleIdentityToken({ sub, nonce }, { audience });
            const authorizationCode = testAppleCode(sub);
            const response = yield* appleSignIn(handler, {
              identityToken,
              nonce,
              authorizationCode,
              device,
            });
            assert.strictEqual(response.status, 200);
            const [row] = yield* sql<{ token: string | null; clientId: string | null }>`SELECT
              apple_refresh_token AS token, apple_client_id AS "clientId" FROM identities
              WHERE subject = ${sub}`;
            assert.isString(row?.token);
            assert.notInclude(row?.token, testAppleRefreshToken(authorizationCode));
            return row?.clientId;
          });
        assert.strictEqual(yield* signIn("000123.http.0010", appleAppId), appleAppId);
        assert.strictEqual(
          yield* signIn("000123.http.0011", appleWebServicesId),
          appleWebServicesId,
        );
        // Only the web sign-in's code is redeemed with its redirect URI, the API's callback.
        const redirects = (yield* TestAppleEndpoint).calls.map((call) => call.form["redirect_uri"]);
        assert.deepStrictEqual(redirects, [undefined, "https://api.lil.tech/v1/auth/apple/web"]);
      }),
    ),
  );

  it.live("signs in even when Apple refuses the authorization code", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        (yield* TestAppleEndpoint).answerWith(() => ({ status: 500, body: "" }));
        const nonce = crypto.randomUUID();
        const identityToken = yield* appleIdentityToken({ sub: "000123.http.0012", nonce });
        const response = yield* appleSignIn(handler, {
          identityToken,
          nonce,
          authorizationCode: testAppleCode("000123.http.0012"),
          device,
        });
        assert.strictEqual(response.status, 200);
      }),
    ),
  );

  it.live("doesn't create accounts from mainland China, but signs existing ones in", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const users = yield* Users;
        const signInAs = (sub: string, country: string) =>
          Effect.gen(function* () {
            const nonce = crypto.randomUUID();
            const identityToken = yield* appleIdentityToken({ sub, nonce });
            return yield* appleSignIn(handler, { identityToken, nonce, device }, country);
          });
        const refused = yield* signInAs("000123.http.0002", "CN");
        assert.deepStrictEqual(refused, {
          status: 451,
          body: {
            _tag: "SignUpUnavailableInRegion",
            message: "New accounts can't be created in your country or region",
          },
        });
        assert.strictEqual(yield* users.count, 0);

        assert.strictEqual((yield* signInAs("000123.http.0002", "US")).status, 200);
        assert.strictEqual((yield* signInAs("000123.http.0002", "CN")).status, 200);
        // Hong Kong has its own code.
        assert.strictEqual((yield* signInAs("000123.http.0003", "HK")).status, 200);
        assert.strictEqual(yield* users.count, 2);
      }),
    ),
  );

  it.live("rejects a token that doesn't verify", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* appleSignIn(handler, { identityToken: "nope", nonce: "n", device });
        assert.strictEqual(response.status, 401);
        assert.propertyVal(response.body, "_tag", "InvalidIdentityToken");
        const malformed = yield* appleSignIn(handler, { identityToken: "nope", device });
        assert.strictEqual(malformed.status, 400);
      }),
    ),
  );
});

describe("POST /v1/auth/google", () => {
  const googleSignIn = (handler: Handler, sub: string, country?: string) =>
    Effect.gen(function* () {
      const nonce = crypto.randomUUID();
      const idToken = yield* googleIdToken({ sub, nonce });
      return yield* send(
        handler,
        fromCountry(
          new Request("https://api.lil.tech/v1/auth/google", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              idToken,
              nonce,
              device: { app: "health-mac", platform: "macos" },
            }),
          }),
          country,
        ),
      );
    });

  it.live("doesn't create an account from mainland China", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* googleSignIn(handler, "100000000000000000002", "CN");
        assert.strictEqual(response.status, 451);
        assert.propertyVal(response.body, "_tag", "SignUpUnavailableInRegion");
        assert.strictEqual(yield* (yield* Users).count, 0);
      }),
    ),
  );

  it.live("signs in with a Google ID token", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* googleSignIn(handler, "100000000000000000001");
        assert.strictEqual(response.status, 200);
        const { accessToken } = response.body as { accessToken: string };
        const me = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(accessToken) }),
        );
        assert.deepStrictEqual(identitiesOf(me.body), [
          { provider: "google", email: "ada@example.com" },
        ]);
      }),
    ),
  );
});

describe("/v1/me/identities", () => {
  const post = (handler: Handler, path: string, accessToken: string, body: unknown) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/me/identities/${path}`, {
        method: "POST",
        headers: { "content-type": "application/json", ...bearer(accessToken) },
        body: JSON.stringify(body),
      }),
    );
  const linkGoogle = (handler: Handler, accessToken: string, sub: string) =>
    Effect.gen(function* () {
      const nonce = crypto.randomUUID();
      const idToken = yield* googleIdToken({ sub, nonce });
      return yield* post(handler, "google", accessToken, { idToken, nonce });
    });
  const linkApple = (handler: Handler, accessToken: string, sub: string, code?: string) =>
    Effect.gen(function* () {
      const nonce = crypto.randomUUID();
      const identityToken = yield* appleIdentityToken({ sub, nonce });
      return yield* post(handler, "apple", accessToken, {
        identityToken,
        nonce,
        ...(code === undefined ? {} : { authorizationCode: code }),
      });
    });
  const unlink = (handler: Handler, accessToken: string, id: string) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/me/identities/${id}`, {
        method: "DELETE",
        headers: bearer(accessToken),
      }),
    );
  const me = (handler: Handler, accessToken: string) =>
    send(handler, new Request("https://api.lil.tech/v1/me", { headers: bearer(accessToken) }));
  const googleSignIn = (handler: Handler, sub: string) =>
    Effect.gen(function* () {
      const nonce = crypto.randomUUID();
      const idToken = yield* googleIdToken({ sub, nonce });
      return yield* send(
        handler,
        new Request("https://api.lil.tech/v1/auth/google", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            idToken,
            nonce,
            device: { app: "health-mac", platform: "macos" },
          }),
        }),
      );
    });

  it.live("links Google to an Apple account, which it then signs in to", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const linked = yield* linkGoogle(handler, tokens.accessToken, "100000000000000000101");
        assert.strictEqual(linked.status, 200);
        assert.deepInclude(linked.body, { provider: "google", email: "ada@example.com" });
        const { body } = yield* me(handler, tokens.accessToken);
        assert.deepStrictEqual(identitiesOf(body), [
          { provider: "apple", email: "ada@privaterelay.appleid.com" },
          { provider: "google", email: "ada@example.com" },
        ]);
        const signedIn = yield* googleSignIn(handler, "100000000000000000101");
        const { accessToken } = signedIn.body as { accessToken: string };
        assert.strictEqual((yield* (yield* AccessTokens).verify(accessToken)).userId, user.id);
      }),
    ),
  );

  it.live("linking an identity again changes nothing, and another user's is refused", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* signIn;
        const first = yield* linkGoogle(handler, ada.tokens.accessToken, "100000000000000000102");
        const again = yield* linkGoogle(handler, ada.tokens.accessToken, "100000000000000000102");
        assert.strictEqual(again.status, 200);
        assert.deepStrictEqual(again.body, first.body);

        const grace = yield* signIn;
        const taken = yield* linkGoogle(handler, grace.tokens.accessToken, "100000000000000000102");
        assert.strictEqual(taken.status, 409);
        assert.propertyVal(taken.body, "_tag", "IdentityInUse");
        assert.lengthOf(yield* (yield* Identities).listForUser(grace.user.id), 1);
        // Signing in with it still reaches the first account; accounts aren't merged.
        assert.lengthOf(yield* (yield* Identities).listForUser(ada.user.id), 2);
      }),
    ),
  );

  it.live("refuses tokens that don't verify", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const nonce = crypto.randomUUID();
        const idToken = yield* googleIdToken({ sub: "100000000000000000103", nonce });
        const wrongNonce = yield* post(handler, "google", tokens.accessToken, {
          idToken,
          nonce: "another",
        });
        assert.strictEqual(wrongNonce.status, 401);
        assert.propertyVal(wrongNonce.body, "_tag", "InvalidIdentityToken");
      }),
    ),
  );

  it.live("unlinks a sign-in method, but never the last one", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const [apple] = yield* (yield* Identities).listForUser(user.id);
        const last = yield* unlink(handler, tokens.accessToken, apple?.id ?? "");
        assert.strictEqual(last.status, 409);
        assert.propertyVal(last.body, "_tag", "LastIdentity");

        yield* linkGoogle(handler, tokens.accessToken, "100000000000000000104");
        assert.strictEqual(
          (yield* unlink(handler, tokens.accessToken, apple?.id ?? "")).status,
          204,
        );
        assert.deepStrictEqual(identitiesOf((yield* me(handler, tokens.accessToken)).body), [
          { provider: "google", email: "ada@example.com" },
        ]);
        // Gone, so it's not found the second time.
        const again = yield* unlink(handler, tokens.accessToken, apple?.id ?? "");
        assert.strictEqual(again.status, 404);
      }),
    ),
  );

  it.live("can't unlink another user's sign-in method", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* signIn;
        const grace = yield* signIn;
        yield* linkGoogle(handler, grace.tokens.accessToken, "100000000000000000105");
        const [graceApple] = yield* (yield* Identities).listForUser(grace.user.id);
        const response = yield* unlink(handler, ada.tokens.accessToken, graceApple?.id ?? "");
        assert.strictEqual(response.status, 404);
        assert.lengthOf(yield* (yield* Identities).listForUser(grace.user.id), 2);
      }),
    ),
  );

  it.live("concurrent unlinks of a user's last two sign-in methods leave one", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        yield* linkGoogle(handler, tokens.accessToken, "100000000000000000106");
        const ids = (yield* (yield* Identities).listForUser(user.id)).map((i) => i.id);
        const statuses = yield* Effect.forEach(
          ids,
          (id) => unlink(handler, tokens.accessToken, id).pipe(Effect.map((r) => r.status)),
          { concurrency: "unbounded" },
        );
        assert.sameMembers(statuses, [204, 409]);
        assert.lengthOf(yield* (yield* Identities).listForUser(user.id), 1);
      }),
    ),
  );

  it.live("linking Apple keeps its refresh token, which unlinking revokes", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const sub = "000123.link.0001";
        const code = testAppleCode(sub);
        const linked = yield* linkApple(handler, tokens.accessToken, sub, code);
        assert.strictEqual(linked.status, 200);
        const { id } = linked.body as MeIdentityBody;
        assert.strictEqual((yield* unlink(handler, tokens.accessToken, id)).status, 204);
        const revoked = (yield* TestAppleEndpoint).calls.filter(
          (call) => call.path === "/auth/revoke",
        );
        assert.deepStrictEqual(
          revoked.map((call) => call.form["token"]),
          [testAppleRefreshToken(code)],
        );
      }),
    ),
  );

  it.live("refuses to link with an access token whose user was deleted", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        yield* (yield* Users).delete(user.id);
        const response = yield* linkGoogle(handler, tokens.accessToken, "100000000000000000107");
        assert.strictEqual(response.status, 401);
      }),
    ),
  );
});

describe("POST /v1/auth/apple/web", () => {
  it.live("hands Apple's form post to the app's callback", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* Effect.promise(() =>
          handler(
            new Request("https://api.lil.tech/v1/auth/apple/web", {
              method: "POST",
              headers: {
                "content-type": "application/x-www-form-urlencoded",
                origin: appleWebOrigin,
              },
              body: new URLSearchParams({
                id_token: "a.b.c",
                code: "c0de",
                state: "s+1",
                user: '{"name":{"firstName":"Ada","lastName":null}}',
                other: "dropped",
              }).toString(),
            }),
          ),
        );
        assert.strictEqual(response.status, 303);
        const location = new URL(response.headers.get("location") ?? "");
        assert.strictEqual(
          `${location.protocol}//${location.host}${location.pathname}`,
          appleWebCallback,
        );
        assert.deepStrictEqual(Object.fromEntries(location.searchParams), {
          id_token: "a.b.c",
          code: "c0de",
          state: "s+1",
          user: '{"name":{"firstName":"Ada","lastName":null}}',
        });
        // The person cancelled: Apple posts an error, which the app gets too.
        const cancelled = yield* Effect.promise(() =>
          handler(
            new Request("https://api.lil.tech/v1/auth/apple/web", {
              method: "POST",
              body: new URLSearchParams({ error: "user_cancelled_authorize", state: "s" }),
            }),
          ),
        );
        assert.strictEqual(cancelled.status, 303);
        assert.strictEqual(
          new URL(cancelled.headers.get("location") ?? "").searchParams.get("error"),
          "user_cancelled_authorize",
        );
        // Not from Apple's page, or too big to be: the app gets an error, never a token.
        const refused = (init: RequestInit) =>
          Effect.promise(async () => {
            const response = await handler(
              new Request("https://api.lil.tech/v1/auth/apple/web", { method: "POST", ...init }),
            );
            return new URL(response.headers.get("location") ?? "").searchParams;
          });
        const forged = yield* refused({
          headers: { origin: "https://evil.example" },
          body: new URLSearchParams({ id_token: "x.y.z", state: "s" }),
        });
        assert.deepStrictEqual(Object.fromEntries(forged), { error: "invalid_origin" });
        const big = yield* refused({ body: "id_token=" + "x".repeat(20_000) });
        assert.deepStrictEqual(Object.fromEntries(big), { error: "request_too_large" });
      }),
    ),
  );
});

describe("POST /v1/auth/dev", () => {
  const devSignIn = (handler: Handler, body: unknown = { displayName: "Dev" }) =>
    send(
      handler,
      new Request("https://api.lil.tech/v1/auth/dev", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
    );

  for (const environment of ["preview", "local"] as const) {
    it.live(`signs in as a new synthetic user in ${environment}`, () =>
      withApi(
        (handler) =>
          Effect.gen(function* () {
            const response = yield* devSignIn(handler);
            assert.strictEqual(response.status, 200);
            const { accessToken } = response.body as { accessToken: string };
            const me = yield* send(
              handler,
              new Request("https://api.lil.tech/v1/me", { headers: bearer(accessToken) }),
            );
            assert.deepInclude(me.body, { displayName: "Dev", identities: [] });
            assert.strictEqual((yield* devSignIn(handler, { platform: "android" })).status, 400);
            // The body is optional, but must be JSON if there is one.
            const empty = yield* send(
              handler,
              new Request("https://api.lil.tech/v1/auth/dev", { method: "POST" }),
            );
            assert.strictEqual(empty.status, 200);
            const malformed = yield* send(
              handler,
              new Request("https://api.lil.tech/v1/auth/dev", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: "{displayName:",
              }),
            );
            assert.strictEqual(malformed.status, 400);
            assert.propertyVal(malformed.body, "_tag", "BadRequest");
          }),
        { environment, version: "1" },
      ),
    );
  }

  for (const environment of ["staging", "prod"] as const) {
    it.live(`doesn't exist in ${environment}`, () =>
      withApi(
        (handler) =>
          Effect.gen(function* () {
            assert.strictEqual((yield* devSignIn(handler)).status, 404);
          }),
        { environment, version: "1" },
      ),
    );
  }

  it.live("signs devices in to the same named account", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const me = (token: string) =>
            send(handler, new Request("https://api.lil.tech/v1/me", { headers: bearer(token) }));
          const phone = (yield* devSignIn(handler, { account: "e2e", platform: "ios" })).body as {
            accessToken: string;
          };
          const mac = (yield* devSignIn(handler, { account: "e2e" })).body as {
            accessToken: string;
          };
          const other = (yield* devSignIn(handler, { account: "other" })).body as {
            accessToken: string;
          };
          const [a, b, c] = [
            (yield* me(phone.accessToken)).body as { id: string; displayName: string },
            (yield* me(mac.accessToken)).body as { id: string },
            (yield* me(other.accessToken)).body as { id: string },
          ];
          assert.strictEqual(a.id, b.id);
          assert.strictEqual(a.displayName, "e2e");
          assert.notStrictEqual(a.id, c.id);
          // A full stage still lets an existing account sign in.
          const users = yield* Users;
          yield* Effect.forEach(
            Array.from({ length: maxDevUsers }),
            () => users.create({ displayName: null }),
            { discard: true },
          );
          assert.strictEqual((yield* devSignIn(handler, { account: "e2e" })).status, 200);
          assert.strictEqual((yield* devSignIn(handler, { account: "new" })).status, 429);
        }),
      { environment: "preview", version: "1" },
    ),
  );

  it.live("refuses once the stage has too many users", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const users = yield* Users;
          yield* Effect.forEach(
            Array.from({ length: maxDevUsers }),
            () => users.create({ displayName: null }),
            { discard: true },
          );
          const response = yield* devSignIn(handler);
          assert.strictEqual(response.status, 429);
          assert.strictEqual(yield* users.count, maxDevUsers);
        }),
      { environment: "preview", version: "1" },
    ),
  );

  it("isn't in the OpenAPI spec", () => {
    assert.notProperty(makeOpenApiSpec().paths, "/v1/auth/dev");
  });
});

describe("GET /v1/sync/changes", () => {
  const note = (id: string, title = "Note") => testNoteMutation(id, title);
  const pull = (handler: Handler, token: string, query = "") =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/sync/changes${query}`, { headers: bearer(token) }),
    );

  it.live("pages through the signed-in user's change log", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const store = (yield* UserStores).forUser(user.id);
        yield* store.applyMutations([note("n1"), note("n2"), note("n3")]);

        const first = yield* pull(handler, tokens.accessToken, "?limit=2");
        assert.strictEqual(first.status, 200);
        assert.deepInclude(first.body, { epoch: 1, next: 2, head: 3, hasMore: true });
        const changes = (first.body as { changes: Array<Record<string, unknown>> }).changes;
        assert.deepStrictEqual(
          changes.map((change) => [change["seq"], change["id"], change["op"]]),
          [
            [1, "n1", "upsert"],
            [2, "n2", "upsert"],
          ],
        );
        assert.deepStrictEqual(changes[0]?.["row"], {
          id: "n1",
          title: "Note",
          pinned: false,
          score: null,
          tags: [],
          createdAt: 1,
        });

        const rest = yield* pull(handler, tokens.accessToken, "?after=2&limit=2");
        assert.deepInclude(rest.body, { next: 3, head: 3, hasMore: false });

        // A cursor at the head gets an empty page.
        const atHead = yield* pull(handler, tokens.accessToken, "?after=3");
        assert.deepStrictEqual(atHead.body, {
          epoch: 1,
          changes: [],
          next: 3,
          head: 3,
          hasMore: false,
        });
      }),
    ),
  );

  it.live("returns an empty log for a new user", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const response = yield* pull(handler, tokens.accessToken);
        assert.deepStrictEqual(response, {
          status: 200,
          body: { epoch: 1, changes: [], next: 0, head: 0, hasMore: false },
        });
      }),
    ),
  );

  it.live("answers 410 for a cursor older than the compaction horizon", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const store = (yield* UserStores).forUser(user.id);
        yield* store.applyMutations([note("n1"), note("n2")]);
        // Compaction deleted the first change.
        const sql = (yield* TestStores).sqlFor(user.id);
        sql?.exec("DELETE FROM changes WHERE seq <= 1");
        sql?.exec("INSERT INTO meta (key, value) VALUES ('horizon', 1)");
        const response = yield* pull(handler, tokens.accessToken, "?after=0");
        assert.strictEqual(response.status, 410);
        assert.deepInclude(response.body, { _tag: "ChangesCompacted", reason: "compacted" });
        assert.strictEqual((yield* pull(handler, tokens.accessToken, "?after=1")).status, 200);
      }),
    ),
  );

  it.live("never returns another user's changes", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* signIn;
        const bob = yield* signIn;
        yield* (yield* UserStores).forUser(ada.user.id).applyMutations([note("ada")]);
        const response = yield* pull(handler, bob.tokens.accessToken);
        assert.deepInclude(response.body, { changes: [], head: 0 });
      }),
    ),
  );

  it.live("requires a session and a valid cursor and limit", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const unauthenticated = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/sync/changes"),
        );
        assert.strictEqual(unauthenticated.status, 401);
        for (const query of ["?after=-1", "?after=x", "?limit=0", "?limit=5001", "?limit=1.5"]) {
          assert.strictEqual((yield* pull(handler, tokens.accessToken, query)).status, 400, query);
        }
        assert.strictEqual((yield* pull(handler, tokens.accessToken, "?limit=5000")).status, 200);
      }),
    ),
  );
});

describe("snapshot downloads", () => {
  const note = testNoteMutation;
  // No quiet period: the tests snapshot right after writing.
  const tinyParts = {
    ...snapshotPolicy,
    minChanges: 1,
    partRecords: 2,
    pageRows: 2,
    quietPeriod: 0,
  };
  const get = (handler: Handler, path: string, token?: string) =>
    send(
      handler,
      new Request(
        `https://api.lil.tech${path}`,
        token === undefined ? {} : { headers: bearer(token) },
      ),
    );
  /** Writes a snapshot of the user's store, as its alarm would. */
  const writeSnapshot = (userId: UserId) =>
    Effect.gen(function* () {
      const testStores = yield* TestStores;
      const sql = testStores.sqlFor(userId);
      if (sql === undefined) return yield* Effect.die("no store");
      yield* writeTestSnapshot(sql, testStores.snapshotFiles, tinyParts);
    });

  it.live("returns no snapshot for a new user", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const response = yield* get(handler, "/v1/sync/snapshot", tokens.accessToken);
        assert.deepStrictEqual(response, { status: 200, body: { epoch: 1 } });
      }),
    ),
  );

  it.live("serves the latest snapshot with part URLs that download it", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        yield* (yield* UserStores)
          .forUser(user.id)
          .applyMutations(["a", "b", "c"].map((id) => note(id)));
        yield* writeSnapshot(user.id);

        const latest = yield* get(handler, "/v1/sync/snapshot", tokens.accessToken);
        const { snapshot } = latest.body as {
          snapshot: {
            id: string;
            seq: number;
            entities: Array<{
              entity: string;
              parts: Array<{ url: string; sha256: string; records: number }>;
            }>;
          };
        };
        assert.strictEqual(snapshot.seq, 3);
        const parts =
          snapshot.entities.find((entity) => entity.entity === "test_note")?.parts ?? [];
        assert.lengthOf(parts, 2);

        const records: Array<unknown> = [];
        for (const part of parts) {
          assert.match(part.url, /^https:\/\/api\.lil\.tech\/v1\/sync\/parts\?token=/);
          // No Authorization header: the URL is the authorization.
          const response = yield* Effect.promise(() => handler(new Request(part.url)));
          assert.strictEqual(response.status, 200);
          assert.strictEqual(response.headers.get("content-type"), "application/gzip");
          const bytes = new Uint8Array(yield* Effect.promise(() => response.arrayBuffer()));
          const digest = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", bytes));
          assert.strictEqual(Buffer.from(digest).toString("hex"), part.sha256);
          records.push(
            ...gunzipSync(bytes)
              .toString()
              .trim()
              .split("\n")
              .map((line) => JSON.parse(line)),
          );
        }
        assert.deepStrictEqual(
          records.map((record) => (record as { id: string }).id),
          ["a", "b", "c"],
        );

        // The same snapshot by ID, with fresh URLs.
        const byId = yield* get(handler, `/v1/sync/snapshots/${snapshot.id}`, tokens.accessToken);
        assert.strictEqual(byId.status, 200);
        assert.propertyVal(byId.body, "id", snapshot.id);
      }),
    ),
  );

  it.live("refuses part URLs that are tampered with or expired", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user } = yield* signIn;
        yield* (yield* UserStores).forUser(user.id).applyMutations([note("a")]);
        yield* writeSnapshot(user.id);
        const snapshot = yield* (yield* UserStores).forUser(user.id).latestSnapshot();
        const key =
          snapshot?.entities.find((entity) => entity.entity === "test_note")?.parts[0]?.key ?? "";

        const partUrls = yield* PartUrls.pipe(Effect.provide(PartUrls.layer));
        const token = yield* partUrls.sign(key);
        const fetchPart = (token: string) =>
          Effect.promise(() =>
            handler(new Request(`https://api.lil.tech/v1/sync/parts?token=${token}`)),
          );
        assert.strictEqual((yield* fetchPart(token)).status, 200);
        assert.strictEqual((yield* fetchPart(`${token}x`)).status, 401);
        // Signed under a test clock at 1970, so it expired long ago.
        const expired = yield* partUrls.sign(key).pipe(Effect.provide(TestClock.layer()));
        assert.strictEqual((yield* fetchPart(expired)).status, 401);
        // An access token isn't a part URL.
        assert.strictEqual((yield* fetchPart((yield* signIn).tokens.accessToken)).status, 401);
      }),
    ),
  );

  it.live("serves a range of a part, so an interrupted download can resume", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user } = yield* signIn;
        yield* (yield* UserStores)
          .forUser(user.id)
          .applyMutations(["a", "b"].map((id) => note(id)));
        yield* writeSnapshot(user.id);
        const snapshot = yield* (yield* UserStores).forUser(user.id).latestSnapshot();
        const key =
          snapshot?.entities.find((entity) => entity.entity === "test_note")?.parts[0]?.key ?? "";
        const bytes = (yield* TestStores).storedSnapshotFiles.get(key) ?? new Uint8Array();
        const token = yield* (yield* PartUrls.pipe(Effect.provide(PartUrls.layer))).sign(key);
        const fetchRange = (range: string) =>
          Effect.promise(() =>
            handler(
              new Request(`https://api.lil.tech/v1/sync/parts?token=${token}`, {
                headers: { range },
              }),
            ),
          );

        const rest = yield* fetchRange("bytes=10-");
        assert.strictEqual(rest.status, 206);
        assert.strictEqual(
          rest.headers.get("content-range"),
          `bytes 10-${bytes.length - 1}/${bytes.length}`,
        );
        assert.strictEqual(rest.headers.get("accept-ranges"), "bytes");
        assert.isNotNull(rest.headers.get("etag"));
        const received = new Uint8Array(yield* Effect.promise(() => rest.arrayBuffer()));
        assert.deepStrictEqual(received, bytes.slice(10));

        const tail = yield* fetchRange("bytes=-5");
        assert.deepStrictEqual(
          new Uint8Array(yield* Effect.promise(() => tail.arrayBuffer())),
          bytes.slice(-5),
        );
        const past = yield* fetchRange(`bytes=${bytes.length}-`);
        assert.strictEqual(past.status, 416);
        assert.strictEqual(past.headers.get("content-range"), `bytes */${bytes.length}`);
      }),
    ),
  );

  it.live("answers 503 while a later epoch's snapshot is being written", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        yield* (yield* UserStores).forUser(user.id).applyMutations([note("a")]);
        (yield* TestStores)
          .sqlFor(user.id)
          ?.exec("INSERT INTO meta (key, value) VALUES ('epoch', 2)");
        const response = yield* get(handler, "/v1/sync/snapshot", tokens.accessToken);
        assert.strictEqual(response.status, 503);
        assert.deepInclude(response.body, { _tag: "SnapshotNotReady", retryAfterSeconds: 60 });
      }),
    ),
  );

  it.live("answers 410 for a snapshot that's gone or someone else's", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* signIn;
        const bob = yield* signIn;
        yield* (yield* UserStores).forUser(ada.user.id).applyMutations([note("a")]);
        yield* writeSnapshot(ada.user.id);
        const snapshot = yield* (yield* UserStores).forUser(ada.user.id).latestSnapshot();

        const theirs = yield* get(
          handler,
          `/v1/sync/snapshots/${snapshot?.id}`,
          bob.tokens.accessToken,
        );
        assert.strictEqual(theirs.status, 410);
        assert.propertyVal(theirs.body, "_tag", "SnapshotGone");
        const unknown = yield* get(handler, "/v1/sync/snapshots/snp_nope", ada.tokens.accessToken);
        assert.strictEqual(unknown.status, 410);
        assert.strictEqual((yield* get(handler, "/v1/sync/snapshot")).status, 401);
      }),
    ),
  );
});

describe("POST /v1/sync/mutations", () => {
  const push = (handler: Handler, token: string, body: unknown) =>
    send(
      handler,
      new Request("https://api.lil.tech/v1/sync/mutations", {
        method: "POST",
        headers: { ...bearer(token), "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
    );
  const pin = (id: string, position: number) => ({
    entity: "health_pin",
    op: "upsert",
    id,
    row: { position },
  });
  const steps = "HKQuantityTypeIdentifierStepCount";
  const weight = "HKQuantityTypeIdentifierBodyMass";
  const mutationId = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

  it.live("applies an app's writes to the change log, once per mutation ID", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const first = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(1),
          mutations: [pin(steps, 1), pin(weight, 2)],
        });
        assert.deepStrictEqual(first, { status: 200, body: { seq: 2 } });
        // Type IDs with digits, e.g. Cardio Fitness, are pins too.
        const vo2Max = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(10),
          mutations: [pin("HKQuantityTypeIdentifierVO2Max", 3)],
        });
        assert.strictEqual(vo2Max.status, 200);

        // A retry gets the same answer and appends nothing, even after other writes.
        const store = (yield* UserStores).forUser(user.id);
        yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(2),
          mutations: [{ entity: "health_pin", op: "delete", id: weight }],
        });
        const retry = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(1),
          mutations: [pin(steps, 1), pin(weight, 2)],
        });
        assert.deepStrictEqual(retry, { status: 200, body: { seq: 2 } });
        const page = yield* store.readChanges(0, 100);
        assert.deepStrictEqual(
          page.changes.map((change) => [change.seq, change.id, change.op]),
          // The weight pin's upsert reads as a delete, since its record is gone.
          [
            [1, steps, "upsert"],
            [2, weight, "delete"],
            [3, "HKQuantityTypeIdentifierVO2Max", "upsert"],
            [4, weight, "delete"],
          ],
        );
        assert.deepStrictEqual(page.changes[0]?.row, { id: steps, position: 1 });

        // Upserts merge, and one that changes nothing appends nothing.
        const same = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(3),
          mutations: [pin(steps, 1)],
        });
        assert.deepStrictEqual(same.body, { seq: 4 });
      }),
    ),
  );

  it.live("refuses entities apps can't write, and invalid rows, applying nothing", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const sample = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(4),
          mutations: [
            pin(steps, 1),
            { entity: "health_characteristic", op: "upsert", id: "x", row: { value: 1 } },
          ],
        });
        assert.strictEqual(sample.status, 400);
        assert.deepInclude(sample.body, {
          _tag: "MutationRejected",
          index: 1,
          message: "Apps can't write health_characteristic",
        });
        const unknown = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(5),
          mutations: [{ entity: "nope", op: "delete", id: "x" }],
        });
        assert.strictEqual(unknown.status, 400);
        const invalid = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(6),
          mutations: [pin(steps, 1), { ...pin("not a type", 2) }],
        });
        assert.strictEqual(invalid.status, 400);
        assert.deepInclude(invalid.body, { _tag: "MutationRejected", index: 1 });
        const noPosition = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(7),
          mutations: [{ entity: "health_pin", op: "upsert", id: steps, row: {} }],
        });
        assert.strictEqual(noPosition.status, 400);
        const store = (yield* UserStores).forUser(user.id);
        assert.deepStrictEqual((yield* store.readChanges(0, 100)).changes, []);

        // A malformed request never reaches the store.
        const badId = yield* push(handler, tokens.accessToken, {
          mutationId: "not-a-uuid",
          mutations: [pin(steps, 1)],
        });
        assert.strictEqual(badId.status, 400);
        const empty = yield* push(handler, tokens.accessToken, {
          mutationId: mutationId(8),
          mutations: [],
        });
        assert.strictEqual(empty.status, 400);
      }),
    ),
  );

  it.live("needs a session", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/sync/mutations", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ mutationId: mutationId(9), mutations: [pin(steps, 1)] }),
          }),
        );
        assert.strictEqual(response.status, 401);
      }),
    ),
  );
});

describe("data exports", () => {
  const exportPolicy = { ...snapshotPolicy, partRecords: 2, pageRows: 2, quietPeriod: 0 };
  const call = (handler: Handler, method: string, path: string, accessToken: string) =>
    send(
      handler,
      new Request(`https://api.lil.tech${path}`, { method, headers: bearer(accessToken) }),
    );
  /** The archive at `url`, as its entries' names and bytes. */
  const download = (handler: Handler, url: string) =>
    Effect.promise(async () => {
      const response = await handler(new Request(url));
      const bytes = new Uint8Array(await response.arrayBuffer());
      return { response, bytes, files: untar(bytes) };
    });
  /** Reads a tar's regular files, checking each header's checksum. */
  const untar = (bytes: Uint8Array) => {
    const files = new Map<string, Uint8Array>();
    const text = (start: number, length: number) =>
      new TextDecoder().decode(bytes.subarray(start, start + length)).replace(/\0.*$/s, "");
    for (let offset = 0; offset + 512 <= bytes.length;) {
      if (bytes.subarray(offset, offset + 512).every((byte) => byte === 0)) break;
      const header = bytes.slice(offset, offset + 512);
      const checksum = parseInt(text(offset + 148, 8), 8);
      header.fill(32, 148, 156);
      assert.strictEqual(
        header.reduce((sum, byte) => sum + byte, 0),
        checksum,
      );
      const size = parseInt(text(offset + 124, 12), 8);
      files.set(text(offset, 100), bytes.slice(offset + 512, offset + 512 + size));
      offset += 512 + Math.ceil(size / 512) * 512;
    }
    return files;
  };
  /** A row in every entity's table, written directly: exports read tables, not the log. */
  const seedEveryEntity = (userId: UserId) =>
    Effect.gen(function* () {
      // Opens the store, so its tables exist.
      yield* (yield* UserStores).forUser(userId).applyMutations([testNoteMutation("note-1")]);
      const sql = (yield* TestStores).sqlFor(userId);
      if (sql === undefined) return yield* Effect.die("no store");
      const values = { text: "x", integer: 1, real: 1.5, boolean: 1, json: "{}" } as const;
      for (const entity of entities) {
        const columns = ["id", ...entity.fields.map((field) => field.column)];
        sql.exec(
          `INSERT INTO "${entity.name}" (${columns.map((column) => `"${column}"`).join(", ")})
            VALUES (${columns.map(() => "?").join(", ")})`,
          `${entity.name}-1`,
          ...entity.fields.map((field) => values[field.type.type]),
        );
      }
      return sql;
    });

  it.live("exports the account, every entity's records and the blobs", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const sql = yield* seedEveryEntity(user.id);
        const blob = new TextEncoder().encode("synthetic ECG voltages");
        const sha = "ab".repeat(32);
        (yield* TestHealthBlobBucket).files.set(`${healthBlobPrefix(user.id)}${sha}`, blob);

        const asked = yield* call(handler, "POST", "/v1/me/exports", tokens.accessToken);
        assert.strictEqual(asked.status, 200);
        assert.deepInclude(asked.body, { ready: false, url: null });
        yield* writeTestSnapshot(sql, (yield* TestStores).snapshotFiles, exportPolicy);
        const latest = yield* call(handler, "GET", "/v1/me/exports/latest", tokens.accessToken);
        const { ready, url, requestedAt } = latest.body as {
          ready: boolean;
          url: string;
          requestedAt: number;
        };
        assert.isTrue(ready);
        assert.strictEqual(requestedAt, (asked.body as { requestedAt: number }).requestedAt);

        const { response, bytes, files } = yield* download(handler, url);
        assert.strictEqual(response.status, 200);
        assert.strictEqual(response.headers.get("content-type"), "application/x-tar");
        assert.strictEqual(Number(response.headers.get("content-length")), bytes.length);
        const folder = `lil-export-${new Date(requestedAt).toISOString().slice(0, 10)}`;
        const names = [...files.keys()];
        assert.includeMembers(names, [
          `${folder}/README.txt`,
          `${folder}/account.json`,
          `${folder}/records/manifest.json`,
          `${folder}/blobs/${sha}`,
        ]);
        assert.deepStrictEqual(files.get(`${folder}/blobs/${sha}`), blob);

        const account = JSON.parse(
          new TextDecoder().decode(files.get(`${folder}/account.json`)),
        ) as Record<string, unknown>;
        assert.deepInclude(account, {
          user: { id: user.id, displayName: "Ada", createdAt: user.createdAt },
        });
        assert.deepStrictEqual(account["identities"], [
          {
            provider: "apple",
            email: "ada@privaterelay.appleid.com",
            emailVerified: true,
            createdAt: (yield* (yield* Identities).listForUser(user.id))[0]?.createdAt,
          },
        ]);
        // Each consent, given or not: Health's, and the agents' of each app.
        assert.deepStrictEqual(Object.keys(account["consents"] as Record<string, unknown>), [
          "health",
          "agents:health",
        ]);

        // Every entity's record, in its own files.
        const exported = new Map<string, Array<Record<string, unknown>>>();
        for (const [name, file] of files) {
          const match = /\/records\/([^/]+)\/\d+\.ndjson\.gz$/.exec(name);
          if (match === null) continue;
          const rows = gunzipSync(file)
            .toString("utf8")
            .split("\n")
            .filter((line) => line !== "")
            .map((line) => JSON.parse(line) as Record<string, unknown>);
          exported.set(match[1] ?? "", [...(exported.get(match[1] ?? "") ?? []), ...rows]);
        }
        assert.sameMembers(
          [...exported.keys()],
          [...entities.map((entity) => entity.name), "test_note"],
        );
        for (const entity of entities) {
          assert.deepInclude(exported.get(entity.name)?.[0], { id: `${entity.name}-1` });
        }
      }),
    ),
  );

  it.live("asking again the same day gets the same export", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const first = yield* call(handler, "POST", "/v1/me/exports", tokens.accessToken);
        const again = yield* call(handler, "POST", "/v1/me/exports", tokens.accessToken);
        assert.strictEqual(
          (again.body as { requestedAt: number }).requestedAt,
          (first.body as { requestedAt: number }).requestedAt,
        );
        // Nothing stored yet: ready at once.
        assert.deepInclude(again.body, { ready: true });
      }),
    ),
  );

  it.live("has no latest export until one is asked for", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const response = yield* call(handler, "GET", "/v1/me/exports/latest", tokens.accessToken);
        assert.strictEqual(response.status, 404);
        assert.propertyVal(response.body, "_tag", "DataExportNotFound");
      }),
    ),
  );

  it.live("refuses a download URL that isn't genuine", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const asked = yield* call(handler, "POST", "/v1/me/exports", tokens.accessToken);
        const url = new URL((asked.body as { url: string }).url);
        url.searchParams.set("token", `${url.searchParams.get("token") ?? ""}x`);
        const response = yield* send(handler, new Request(url));
        assert.strictEqual(response.status, 401);
      }),
    ),
  );

  it.live("says so when the account holds more files than one archive can", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const files = (yield* TestHealthBlobBucket).files;
        for (let index = 0; index <= maxArchiveFiles; index++) {
          files.set(
            `${healthBlobPrefix(user.id)}${index.toString(16).padStart(64, "0")}`,
            new Uint8Array(1),
          );
        }
        const asked = yield* call(handler, "POST", "/v1/me/exports", tokens.accessToken);
        const response = yield* send(handler, new Request((asked.body as { url: string }).url));
        assert.strictEqual(response.status, 507);
        assert.propertyVal(response.body, "_tag", "DataExportTooLarge");
      }),
    ),
  );

  it.live("a blob that's gone fails the download, rather than ending it early", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const files = (yield* TestHealthBlobBucket).files;
        const key = `${healthBlobPrefix(user.id)}${"cd".repeat(32)}`;
        files.set(key, new Uint8Array(10));
        const asked = yield* call(handler, "POST", "/v1/me/exports", tokens.accessToken);
        const response = yield* Effect.promise(() =>
          handler(new Request((asked.body as { url: string }).url)),
        );
        files.delete(key);
        const read = yield* Effect.promise(() =>
          response.arrayBuffer().then(
            () => "finished",
            () => "failed",
          ),
        );
        assert.strictEqual(read, "failed");
      }),
    ),
  );
});

describe("GET /v1/sync/live", () => {
  const connect = (handler: Handler, headers: Record<string, string>) =>
    send(handler, new Request("https://api.lil.tech/v1/sync/live", { headers }));

  it.live("hands an authenticated WebSocket upgrade to the user's store", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const response = yield* connect(handler, {
          ...bearer(tokens.accessToken),
          upgrade: "websocket",
          [sessionExpiresHeader]: "1",
        });
        assert.strictEqual(response.status, 200);
        // The store got the token's expiry from the Worker, not the client's header.
        assert.deepStrictEqual(response.body, {
          store: `user:${user.id}`,
          expiresAt: String(tokens.accessTokenExpiresAt),
        });
      }),
    ),
  );

  it.live("refuses a missing or invalid token, and requests that aren't WebSockets", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        assert.strictEqual((yield* connect(handler, { upgrade: "websocket" })).status, 401);
        assert.strictEqual(
          (yield* connect(handler, { ...bearer("nope"), upgrade: "websocket" })).status,
          401,
        );
        const plain = yield* connect(handler, bearer(tokens.accessToken));
        assert.strictEqual(plain.status, 426);
      }),
    ),
  );
});

describe("/v1/health/batches", () => {
  const batchId = "00000000-0000-4000-8000-0000000000b1";
  const lines = [
    {
      entity: "health_sample",
      op: "upsert",
      id: "6f1c2a40-0000-4000-8000-000000000001",
      row: {
        type: "HKQuantityTypeIdentifierStepCount",
        startDate: 1760400000000,
        endDate: 1760400060000,
        value: 12,
        unit: "count",
        sourceName: "Test iPhone",
        sourceBundleId: "com.apple.health.00000000",
      },
    },
  ];
  const upload = (handler: Handler, token: string, id: string, body: Uint8Array) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/health/batches/${id}`, {
        method: "PUT",
        headers: { ...bearer(token), "content-type": "application/gzip" },
        body: body as Uint8Array<ArrayBuffer>,
      }),
    );
  /** A signed-in user who consented to processing their Health data. */
  const consentingSignIn = Effect.gen(function* () {
    const session = yield* signIn;
    yield* (yield* Consents).grant(session.user.id, "health", healthConsentPolicyVersion);
    return session;
  });
  const status = (handler: Handler, token: string, id: string) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/health/batches/${id}`, { headers: bearer(token) }),
    );

  it.live("queues an upload once, and reports its status until it's applied", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* consentingSignIn;
        const outbox = yield* TestHealthOutbox;

        const first = yield* upload(handler, tokens.accessToken, batchId, batchFile(lines));
        assert.strictEqual(first.status, 202);
        assert.deepInclude(first.body, { id: batchId, status: "queued" });
        assert.strictEqual(outbox.sent.length, 1);
        assert.deepInclude(outbox.sent[0], { userId: user.id, batchId });
        // The uploading device, for device-scoped records.
        assert.match(outbox.sent[0]?.deviceId ?? "", /^dev_/);
        assert.isTrue(outbox.files.has(`health-batches/${user.id}/${batchId}.ndjson.gz`));

        // A retried upload is answered with the batch's status and isn't queued again.
        const retried = yield* upload(handler, tokens.accessToken, batchId, batchFile(lines));
        assert.deepInclude(retried.body, { id: batchId, status: "queued" });
        assert.lengthOf(outbox.sent, 1);

        // The queue consumer applies it.
        const [message] = outbox.sent;
        if (message !== undefined) yield* ingestHealthBatch(message);
        const applied = yield* status(handler, tokens.accessToken, batchId);
        assert.strictEqual(applied.status, 200);
        assert.deepInclude(applied.body, { status: "applied", lines: 1, applied: 1, rejected: 0 });
        const changes = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/sync/changes", {
            headers: bearer(tokens.accessToken),
          }),
        );
        assert.deepInclude(changes.body, { head: 1 });
      }),
    ),
  );

  it.live("takes uploads only with consent to the current policy", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const outbox = yield* TestHealthOutbox;
        const consent = (method: string, body?: unknown) =>
          send(
            handler,
            new Request("https://api.lil.tech/v1/me/consents/health", {
              method,
              headers: { ...bearer(tokens.accessToken), "content-type": "application/json" },
              ...(body === undefined ? {} : { body: JSON.stringify(body) }),
            }),
          );
        const refused = {
          status: 403,
          body: { _tag: "ConsentRequired", required: healthConsentPolicyVersion },
        };

        assert.deepStrictEqual(yield* consent("GET"), {
          status: 200,
          body: { required: healthConsentPolicyVersion, given: null, current: false },
        });
        assert.deepStrictEqual(
          yield* upload(handler, tokens.accessToken, batchId, batchFile(lines)),
          refused,
        );
        assert.lengthOf(outbox.sent, 0);
        assert.strictEqual(outbox.files.size, 0);

        // Consent to an older policy isn't recorded.
        assert.deepStrictEqual(yield* consent("POST", { policyVersion: "2026-01-01" }), {
          status: 409,
          body: { _tag: "ConsentOutdated", required: healthConsentPolicyVersion },
        });
        assert.propertyVal((yield* consent("GET")).body, "current", false);

        const given = yield* consent("POST", { policyVersion: healthConsentPolicyVersion });
        assert.strictEqual(given.status, 200);
        assert.deepInclude(given.body, { required: healthConsentPolicyVersion, current: true });
        const grantedAt = (given.body as { given: { grantedAt: number } }).given.grantedAt;
        // Consenting again, even at the same time, keeps the first record.
        const again = yield* Effect.all(
          [
            consent("POST", { policyVersion: healthConsentPolicyVersion }),
            consent("POST", { policyVersion: healthConsentPolicyVersion }),
          ],
          { concurrency: "unbounded" },
        );
        for (const response of again) assert.deepStrictEqual(response.body, given.body);
        const sql = yield* SqlClient.SqlClient;
        assert.deepStrictEqual(yield* sql`SELECT count(*) AS n FROM consents`, [{ n: 1 }]);
        assert.deepStrictEqual((yield* consent("GET")).body, {
          required: healthConsentPolicyVersion,
          given: { policyVersion: healthConsentPolicyVersion, grantedAt },
          current: true,
        });
        assert.deepInclude(yield* upload(handler, tokens.accessToken, batchId, batchFile(lines)), {
          status: 202,
        });

        // Withdrawn: new batches are refused, while the one it has still answers.
        assert.strictEqual((yield* consent("DELETE")).status, 204);
        assert.deepStrictEqual((yield* consent("GET")).body, {
          required: healthConsentPolicyVersion,
          given: null,
          current: false,
        });
        const next = "00000000-0000-4000-8000-0000000000b4";
        assert.deepStrictEqual(
          yield* upload(handler, tokens.accessToken, next, batchFile(lines)),
          refused,
        );
        assert.deepInclude(yield* upload(handler, tokens.accessToken, batchId, batchFile(lines)), {
          status: 202,
        });
        assert.lengthOf(outbox.sent, 1);

        // The records stay, as proof of consent.
        const rows = yield* sql<{ withdrawn: number }>`
          SELECT count(*) AS withdrawn FROM consents WHERE withdrawn_at IS NOT NULL`;
        assert.deepStrictEqual(rows, [{ withdrawn: 1 }]);
      }),
    ),
  );

  it.live("refuses new uploads once the store is full", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* consentingSignIn;
        const outbox = yield* TestHealthOutbox;
        yield* upload(handler, tokens.accessToken, batchId, batchFile(lines));
        const sql = (yield* TestStores).sqlFor(user.id);
        assert.isDefined(sql);
        sql.setDatabaseSize(storageQuotaBytes);

        const refused = yield* upload(
          handler,
          tokens.accessToken,
          "00000000-0000-4000-8000-0000000000b3",
          batchFile(lines),
        );
        assert.deepStrictEqual(refused, {
          status: 507,
          body: { _tag: "StorageFull", quotaBytes: storageQuotaBytes },
        });
        // Nothing reached the files or the queue.
        assert.lengthOf(outbox.sent, 1);
        assert.strictEqual(outbox.files.size, 1);
        // A batch it already has still answers with its status.
        const retried = yield* upload(handler, tokens.accessToken, batchId, batchFile(lines));
        assert.deepInclude(retried, { status: 202 });
      }),
    ),
  );

  /** Signs in, with Apple's refresh token stored as a sign-in with a code would. */
  const signInWithAppleToken = Effect.gen(function* () {
    const session = yield* signIn;
    const [identity] = yield* (yield* Identities).listForUser(session.user.id);
    const subject = identity?.subject ?? "";
    const code = testAppleCode(subject);
    const encrypted = yield* (yield* AppleTokens).exchange(code, { clientId: appleAppId, subject });
    yield* (yield* Identities).saveAppleToken(subject, Option.getOrThrow(encrypted), appleAppId);
    return { ...session, appleRefreshToken: testAppleRefreshToken(code) };
  });
  const deleteMe = (handler: Handler, accessToken: string) =>
    send(
      handler,
      new Request("https://api.lil.tech/v1/me", { method: "DELETE", headers: bearer(accessToken) }),
    );

  it.live("DELETE /v1/me revokes the account's Apple token", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens, appleRefreshToken } = yield* signInWithAppleToken;
        assert.strictEqual((yield* deleteMe(handler, tokens.accessToken)).status, 204);
        const revoked = (yield* TestAppleEndpoint).calls.filter(
          (call) => call.path === "/auth/revoke",
        );
        assert.deepStrictEqual(
          revoked.map((call) => [call.form["token"], call.form["client_id"]]),
          [[appleRefreshToken, appleAppId]],
        );
        assert.lengthOf(yield* (yield* AppleTokenRevocations).listDue(Date.now() + 1000, 10), 0);
      }),
    ),
  );

  it.live("DELETE /v1/me leaves an Apple token it couldn't revoke for later", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signInWithAppleToken;
        (yield* TestAppleEndpoint).answerWith(() => ({ status: 503, body: "" }));
        assert.strictEqual((yield* deleteMe(handler, tokens.accessToken)).status, 204);
        const [waiting] = yield* (yield* AppleTokenRevocations).listDue(Date.now() + 3_601_000, 10);
        assert.deepInclude(waiting, { clientId: appleAppId, attempts: 1 });
      }),
    ),
  );

  it.live("DELETE /v1/me removes the account and all of its data", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* consentingSignIn;
        const outbox = yield* TestHealthOutbox;
        // Some health data, and a batch still waiting in the queue.
        yield* upload(handler, tokens.accessToken, batchId, batchFile(lines));
        const [applied] = outbox.sent;
        if (applied !== undefined) yield* ingestHealthBatch(applied);
        const waiting = "00000000-0000-4000-8000-0000000000b2";
        yield* upload(handler, tokens.accessToken, waiting, batchFile(lines));
        const store = (yield* TestStores).sqlFor(user.id);
        assert.isAbove(
          store?.exec("SELECT count(*) AS n FROM health_sample")[0]?.["n"] as number,
          0,
        );

        const deleted = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", {
            method: "DELETE",
            headers: bearer(tokens.accessToken),
          }),
        );
        assert.strictEqual(deleted.status, 204);
        // The store is emptied by its alarm, which is due at once.
        yield* (yield* UserStores).forUser(user.id).alarm();

        // Nothing left in the core database…
        const sql = yield* SqlClient.SqlClient;
        for (const table of [
          "users",
          "identities",
          "devices",
          "sessions",
          "connections",
          "consents",
        ]) {
          const column = table === "users" ? "id" : "user_id";
          const rows = yield* sql.unsafe(`SELECT count(*) AS n FROM ${table} WHERE ${column} = ?`, [
            user.id,
          ]);
          assert.deepStrictEqual(rows, [{ n: 0 }], table);
        }
        // …in the user's store, beyond the mark that the account is gone…
        for (const table of ["health_sample", "changes", "health_batches", "snapshots"]) {
          assert.deepStrictEqual(
            store?.exec(`SELECT count(*) AS n FROM ${table}`),
            [{ n: 0 }],
            table,
          );
        }
        // …or in R2.
        assert.isFalse(
          [...outbox.files.keys()].some((key) => key.startsWith(`health-batches/${user.id}/`)),
        );

        // The tokens stop working: the refresh token at once, and the access token for writes.
        assert.strictEqual((yield* refresh(handler, tokens.refreshToken)).status, 401);
        const me = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.accessToken) }),
        );
        assert.strictEqual(me.status, 401);
        const late = yield* upload(
          handler,
          tokens.accessToken,
          "00000000-0000-4000-8000-0000000000b3",
          batchFile(lines),
        );
        assert.strictEqual(late.status, 401);
        // Refused before anything reached R2.
        assert.isFalse(
          outbox.files.has(
            `health-batches/${user.id}/00000000-0000-4000-8000-0000000000b3.ndjson.gz`,
          ),
        );
        assert.lengthOf(outbox.sent, 2);

        // The batch that was still queued is dropped, file and all.
        for (const message of outbox.sent.slice(1)) yield* ingestHealthBatch(message);
        assert.deepStrictEqual(store?.exec("SELECT count(*) AS n FROM health_sample"), [{ n: 0 }]);
        assert.isFalse(
          [...outbox.files.keys()].some((key) => key.startsWith(`health-batches/${user.id}/`)),
        );
      }),
    ),
  );

  it.live("keeps each user's batches to themselves", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* consentingSignIn;
        const bob = yield* consentingSignIn;
        yield* upload(handler, ada.tokens.accessToken, batchId, batchFile(lines));
        const response = yield* status(handler, bob.tokens.accessToken, batchId);
        assert.strictEqual(response.status, 404);
        assert.propertyVal(response.body, "_tag", "HealthBatchNotFound");
      }),
    ),
  );

  it.live("rejects invalid IDs, oversized files and missing sessions", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* consentingSignIn;
        for (const id of ["not-a-uuid", batchId.toUpperCase()]) {
          assert.strictEqual(
            (yield* upload(handler, tokens.accessToken, id, batchFile(lines))).status,
            400,
          );
        }
        const tooLarge = yield* upload(
          handler,
          tokens.accessToken,
          batchId,
          new Uint8Array(16 * 1024 * 1024 + 1),
        );
        assert.strictEqual(tooLarge.status, 413);
        assert.lengthOf((yield* TestHealthOutbox).sent, 0);
        const anonymous = yield* send(
          handler,
          new Request(`https://api.lil.tech/v1/health/batches/${batchId}`, { method: "PUT" }),
        );
        assert.strictEqual(anonymous.status, 401);
      }),
    ),
  );
});

describe("/v1/health/blobs", () => {
  // Synthetic bytes, e.g. an ECG's voltages.
  const blob = new Uint8Array(Array.from({ length: 1000 }, (_, index) => index % 251));
  const hashOf = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex") as string;
  const sha256 = hashOf(blob);
  const consentingSignIn = Effect.gen(function* () {
    const session = yield* signIn;
    yield* (yield* Consents).grant(session.user.id, "health", healthConsentPolicyVersion);
    return session;
  });
  const upload = (handler: Handler, token: string, hash: string, body: Uint8Array) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/health/blobs/${hash}`, {
        method: "PUT",
        headers: { ...bearer(token), "content-type": "application/octet-stream" },
        body: body as Uint8Array<ArrayBuffer>,
      }),
    );
  const download = (handler: Handler, token: string, hash: string) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/health/blobs/${hash}`, { headers: bearer(token) }),
    );
  const fetchBytes = (handler: Handler, url: string, headers: Record<string, string> = {}) =>
    Effect.promise(async () => {
      const response = await handler(new Request(url, { headers }));
      return {
        status: response.status,
        headers: response.headers,
        bytes: new Uint8Array(await response.arrayBuffer()),
      };
    });

  it.live("stores a blob once, counts it towards the quota, and serves it to its owner", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* consentingSignIn;
        const bucket = (yield* TestHealthBlobBucket).files;
        const store = (yield* UserStores).forUser(user.id);
        const before = yield* store.storageBytes();

        assert.deepStrictEqual(yield* upload(handler, tokens.accessToken, sha256, blob), {
          status: 200,
          body: { sha256, size: 1000 },
        });
        assert.deepStrictEqual([...bucket.keys()], [`health-blobs/${user.id}/${sha256}`]);
        assert.strictEqual((yield* store.storageBytes()) - before, 1000);
        // Uploading it again changes nothing.
        assert.deepStrictEqual(yield* upload(handler, tokens.accessToken, sha256, blob), {
          status: 200,
          body: { sha256, size: 1000 },
        });
        assert.strictEqual((yield* store.storageBytes()) - before, 1000);

        const link = yield* download(handler, tokens.accessToken, sha256);
        assert.strictEqual(link.status, 200);
        const { url, expiresAt } = link.body as { url: string; expiresAt: number };
        assert.match(url, /^https:\/\/api\.lil\.tech\/v1\/health\/blob-downloads\?token=/);
        assert.isAbove(expiresAt, Date.now());
        // No `Authorization` needed: the URL is the authorization.
        const whole = yield* fetchBytes(handler, url);
        assert.strictEqual(whole.status, 200);
        assert.deepStrictEqual(whole.bytes, blob);
        assert.strictEqual(whole.headers.get("content-type"), "application/octet-stream");
        const part = yield* fetchBytes(handler, url, { range: "bytes=10-19" });
        assert.strictEqual(part.status, 206);
        assert.deepStrictEqual(part.bytes, blob.slice(10, 20));
        assert.strictEqual(part.headers.get("content-range"), "bytes 10-19/1000");
        // A snapshot part URL's token can't be used for a blob, or the other way round.
        const swapped = url.replace("/v1/health/blob-downloads", "/v1/sync/parts");
        assert.strictEqual((yield* fetchBytes(handler, swapped)).status, 401);
      }),
    ),
  );

  it.live("keeps each user's blobs to themselves", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* consentingSignIn;
        const bob = yield* consentingSignIn;
        yield* upload(handler, ada.tokens.accessToken, sha256, blob);
        assert.deepStrictEqual(yield* download(handler, bob.tokens.accessToken, sha256), {
          status: 404,
          body: { _tag: "HealthBlobNotFound", sha256 },
        });
        // Bob uploading the same bytes stores his own copy.
        yield* upload(handler, bob.tokens.accessToken, sha256, blob);
        assert.strictEqual((yield* TestHealthBlobBucket).files.size, 2);
      }),
    ),
  );

  it.live("refuses wrong hashes, oversized blobs, missing consent and a full account", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const bucket = (yield* TestHealthBlobBucket).files;
        assert.strictEqual(
          (yield* upload(handler, tokens.accessToken, sha256.toUpperCase(), blob)).status,
          400,
        );
        const tooLarge = new Uint8Array(16 * 1024 * 1024 + 1);
        assert.deepStrictEqual(
          yield* upload(handler, tokens.accessToken, hashOf(tooLarge), tooLarge),
          { status: 413, body: { _tag: "HealthBlobTooLarge", maxBytes: 16 * 1024 * 1024 } },
        );
        assert.deepStrictEqual(yield* upload(handler, tokens.accessToken, sha256, blob), {
          status: 403,
          body: { _tag: "ConsentRequired", required: healthConsentPolicyVersion },
        });
        assert.strictEqual(bucket.size, 0);

        yield* (yield* Consents).grant(user.id, "health", healthConsentPolicyVersion);
        yield* upload(handler, tokens.accessToken, sha256, blob);
        const sql = (yield* TestStores).sqlFor(user.id);
        assert.isDefined(sql);
        sql.setDatabaseSize(storageQuotaBytes);
        const next = blob.slice(1);
        assert.deepStrictEqual(yield* upload(handler, tokens.accessToken, hashOf(next), next), {
          status: 507,
          body: { _tag: "StorageFull", quotaBytes: storageQuotaBytes },
        });
        // A blob it has still answers.
        assert.strictEqual((yield* upload(handler, tokens.accessToken, sha256, blob)).status, 200);
        assert.strictEqual(bucket.size, 1);
        sql.setDatabaseSize(0);
        // Bytes that don't match their name aren't stored.
        const other = "0".repeat(64);
        assert.deepStrictEqual(yield* upload(handler, tokens.accessToken, other, blob), {
          status: 400,
          body: { _tag: "HealthBlobHashMismatch", sha256: other, actual: sha256 },
        });
        assert.strictEqual(bucket.size, 1);
      }),
    ),
  );

  it.live("are deleted with the account", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* consentingSignIn;
        yield* upload(handler, tokens.accessToken, sha256, blob);
        const store = (yield* TestStores).sqlFor(user.id);
        const deleted = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", {
            method: "DELETE",
            headers: bearer(tokens.accessToken),
          }),
        );
        assert.strictEqual(deleted.status, 204);
        yield* (yield* UserStores).forUser(user.id).alarm();
        assert.strictEqual((yield* TestHealthBlobBucket).files.size, 0);
        assert.deepStrictEqual(store?.exec("SELECT count(*) AS n FROM health_blobs"), [{ n: 0 }]);
        assert.strictEqual((yield* download(handler, tokens.accessToken, sha256)).status, 401);
      }),
    ),
  );
});

describe("rate limits", () => {
  /** Rate limits that allow `max` requests per key for each limit, unlimited where unset. */
  const limitsAllowing = (max: Partial<Record<RateLimitName, number>>) => {
    const counts = new Map<string, number>();
    const counter =
      (limit: RateLimitName): RateLimitCounter =>
      (key) =>
        Effect.sync(() => {
          const count = (counts.get(`${limit}/${key}`) ?? 0) + 1;
          counts.set(`${limit}/${key}`, count);
          return count <= (max[limit] ?? Infinity);
        });
    return RateLimits.make({
      signIn: counter("signIn"),
      user: counter("user"),
      refresh: counter("refresh"),
      clientRegistration: counter("clientRegistration"),
      agentToken: counter("agentToken"),
      agent: counter("agent"),
    });
  };
  const from = (address: string) => ({ "cf-connecting-ip": address });
  const tooMany = { _tag: "TooManyRequests", retryAfterSeconds: 60 };
  const refreshFrom = (handler: Handler, address: string) =>
    send(
      handler,
      new Request("https://api.lil.tech/v1/auth/refresh", {
        method: "POST",
        headers: { "content-type": "application/json", ...from(address) },
        body: JSON.stringify({ refreshToken: "lrt_x" }),
      }),
    );
  const appleFrom = (handler: Handler, address: string) =>
    send(
      handler,
      new Request("https://api.lil.tech/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json", ...from(address) },
        body: JSON.stringify({
          identityToken: "x",
          nonce: "x",
          device: { app: "health-ios", platform: "ios" },
        }),
      }),
    );

  it.live("limits sign-ins per IP address", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          // Counted before the token is checked, so these are 401s until the limit.
          assert.strictEqual((yield* appleFrom(handler, "192.0.2.1")).status, 401);
          assert.strictEqual((yield* appleFrom(handler, "192.0.2.1")).status, 401);
          assert.deepStrictEqual(yield* appleFrom(handler, "192.0.2.1"), {
            status: 429,
            body: tooMany,
          });
          // Refreshes have their own limit.
          assert.strictEqual((yield* refreshFrom(handler, "192.0.2.1")).status, 401);
          // Other addresses have their own limit, and requests without one (local runs) have none.
          assert.strictEqual((yield* appleFrom(handler, "192.0.2.2")).status, 401);
          const google = yield* send(
            handler,
            new Request("https://api.lil.tech/v1/auth/google", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                idToken: "x",
                nonce: "x",
                device: { app: "health-ios", platform: "ios" },
              }),
            }),
          );
          assert.notStrictEqual(google.status, 429);
        }),
      undefined,
      limitsAllowing({ signIn: 2 }),
    ),
  );

  it.live("limits refreshes per IP address", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          assert.strictEqual((yield* refreshFrom(handler, "192.0.2.1")).status, 401);
          assert.deepStrictEqual(yield* refreshFrom(handler, "192.0.2.1"), {
            status: 429,
            body: tooMany,
          });
          assert.strictEqual((yield* appleFrom(handler, "192.0.2.1")).status, 401);
          for (let i = 0; i < 3; i++)
            assert.strictEqual((yield* refresh(handler, "lrt_x")).status, 401);
        }),
      undefined,
      limitsAllowing({ refresh: 1 }),
    ),
  );

  it.live("counts IPv6 addresses by their /64", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          assert.strictEqual((yield* appleFrom(handler, "2001:db8:1:2::1")).status, 401);
          assert.strictEqual((yield* appleFrom(handler, "2001:db8:1:2:ffff::7")).status, 429);
          assert.strictEqual((yield* appleFrom(handler, "2001:db8:1:3::1")).status, 401);
        }),
      undefined,
      limitsAllowing({ signIn: 1 }),
    ),
  );

  it("keys addresses", () => {
    assert.strictEqual(addressKey("192.0.2.1"), "192.0.2.1");
    assert.strictEqual(addressKey("2001:db8:1:2:3:4:5:6"), "2001:db8:1:2::/64");
    assert.strictEqual(addressKey("2001:0DB8:0001:0002::9"), "2001:db8:1:2::/64");
    assert.strictEqual(addressKey("2001:db8::1"), "2001:db8:0:0::/64");
    assert.strictEqual(addressKey("::1"), "0:0:0:0::/64");
    assert.strictEqual(addressKey("::ffff:192.0.2.1"), "192.0.2.1");
  });

  it.live("limits dev sign-ins per IP address", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const devSignIn = Effect.promise(() =>
            handler(
              new Request("https://api.lil.tech/v1/auth/dev", {
                method: "POST",
                headers: from("192.0.2.1"),
              }),
            ),
          );
          assert.strictEqual((yield* devSignIn).status, 200);
          const limited = yield* devSignIn;
          assert.strictEqual(limited.status, 429);
          assert.strictEqual(limited.headers.get("retry-after"), "60");
          assert.deepStrictEqual(yield* Effect.promise(() => limited.json()), tooMany);
          // Refused before creating anyone.
          assert.strictEqual(yield* (yield* Users).count, 1);
        }),
      { environment: "preview", version: "1" },
      limitsAllowing({ signIn: 1 }),
    ),
  );

  it.live("limits authenticated requests per user", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const ada = yield* signIn;
          const grace = yield* signIn;
          const me = (token: string) =>
            send(handler, new Request("https://api.lil.tech/v1/me", { headers: bearer(token) }));
          assert.strictEqual((yield* me(ada.tokens.accessToken)).status, 200);
          const changes = yield* send(
            handler,
            new Request("https://api.lil.tech/v1/sync/changes", {
              headers: bearer(ada.tokens.accessToken),
            }),
          );
          assert.strictEqual(changes.status, 200);
          assert.deepStrictEqual(yield* me(ada.tokens.accessToken), { status: 429, body: tooMany });
          const live = yield* Effect.promise(() =>
            handler(
              new Request("https://api.lil.tech/v1/sync/live", {
                headers: { ...bearer(ada.tokens.accessToken), upgrade: "websocket" },
              }),
            ),
          );
          assert.strictEqual(live.status, 429);
          assert.strictEqual(live.headers.get("retry-after"), "60");
          // Counted per user, not per device or token.
          assert.strictEqual((yield* me(grace.tokens.accessToken)).status, 200);
          // An invalid token isn't counted against anyone.
          assert.strictEqual((yield* me("nope")).status, 401);
          // Signing out isn't limited, so it always ends the session.
          const signOut = yield* send(
            handler,
            new Request("https://api.lil.tech/v1/auth/sign-out", {
              method: "POST",
              headers: bearer(ada.tokens.accessToken),
            }),
          );
          assert.strictEqual(signOut.status, 204);
          assert.strictEqual((yield* refresh(handler, ada.tokens.refreshToken)).status, 401);
        }),
      undefined,
      limitsAllowing({ user: 2 }),
    ),
  );

  it.live("lets requests through when counting fails", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const { tokens } = yield* signIn;
          const response = yield* send(
            handler,
            new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.accessToken) }),
          );
          assert.strictEqual(response.status, 200);
          assert.strictEqual((yield* refreshFrom(handler, "192.0.2.1")).status, 401);
          assert.strictEqual((yield* appleFrom(handler, "192.0.2.1")).status, 401);
        }),
      undefined,
      RateLimits.make({
        signIn: () => Effect.fail(new Error("binding unavailable")),
        user: () => Effect.fail(new Error("binding unavailable")),
        refresh: () => Effect.fail(new Error("binding unavailable")),
        clientRegistration: () => Effect.fail(new Error("binding unavailable")),
        agentToken: () => Effect.fail(new Error("binding unavailable")),
        agent: () => Effect.fail(new Error("binding unavailable")),
      }),
    ),
  );

  it("documents 429s on rate-limited endpoints", () => {
    const { paths } = makeOpenApiSpec();
    for (const [path, method] of [
      ["/v1/auth/refresh", "post"],
      ["/v1/auth/apple", "post"],
      ["/v1/auth/google", "post"],
      ["/v1/me", "get"],
      ["/v1/sync/changes", "get"],
      ["/v1/health/batches/{id}", "put"],
    ] as const) {
      assert.property(paths[path]?.[method]?.responses, "429", `${method} ${path}`);
    }
    assert.property(paths["/v1/health/batches/{id}"]?.put?.responses, "507");
    assert.notProperty(paths["/v1/status"]?.get?.responses, "429");
  });

  it("gives each stage and limit its own namespace", () => {
    const limits = Object.keys(rateLimits) as Array<RateLimitName>;
    const ids = ["prod", "staging", "pr-88", "pr-89"].flatMap((stage) =>
      limits.map((limit) => rateLimitNamespaceId(stage, limit)),
    );
    assert.strictEqual(new Set(ids).size, ids.length);
    for (const id of ids) {
      assert.match(id, /^[1-9]\d+$/);
      assert.isBelow(Number(id), 2 ** 31);
    }
    // Fixed per limit, so a deploy never resets counters.
    assert.strictEqual(rateLimitNamespaceId("prod", "user"), "27608502");
  });
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
  const apiWorkerProps = makeApiWorkerProps((id) => Effect.succeed(Redacted.make(id)));

  it.effect("runs without a Stage, as it does inside the deployed Worker", () =>
    Effect.gen(function* () {
      const props = yield* apiWorkerProps;
      assert.isUndefined((props as { domain?: object }).domain);
    }),
  );

  it.effect("picks the custom domain for the stage at deploy time", () =>
    Effect.gen(function* () {
      const props = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "staging"),
        withEnv({
          LIL_ENVIRONMENT: "staging",
          LIL_VERSION: "45aa829",
          LIL_APPLE_SIGN_IN_KEY: "apple-key",
        }),
      );
      // The MCP servers' host is the same Worker's (`src/oauth/Hosts.ts`).
      assert.deepStrictEqual((props as { domain?: object }).domain, {
        name: "api.staging.lil.tech",
        aliases: ["mcp.staging.lil.tech"],
      });
      // So a Client ID Metadata Document's URL can't reach Cloudflare-internal addresses.
      assert.deepStrictEqual((props as { compatibility?: object }).compatibility, {
        flags: ["global_fetch_strictly_public"],
      });
      assert.deepStrictEqual((props as { env?: object }).env, {
        LIL_SESSION_KEY: Redacted.make("SessionSigningKey"),
        LIL_TOKEN_KEY: Redacted.make("AppleTokenKey"),
        LIL_APPLE_SIGN_IN_KEY: Redacted.make("apple-key"),
      });
    }),
  );

  it.effect("needs the Sign in with Apple key for staging and prod, but not previews", () =>
    Effect.gen(function* () {
      const exit = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "prod"),
        withEnv({ LIL_ENVIRONMENT: "prod", LIL_VERSION: "45aa829" }),
        Effect.exit,
      );
      assert.isTrue(Exit.isFailure(exit));
      const preview = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "pr-12"),
        withEnv({ LIL_ENVIRONMENT: "preview", LIL_VERSION: "45aa829" }),
      );
      assert.notProperty((preview as { env?: object }).env, "LIL_APPLE_SIGN_IN_KEY");
      // CI gets an empty string for a missing secret.
      const empty = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "prod"),
        withEnv({ LIL_ENVIRONMENT: "prod", LIL_VERSION: "45aa829", LIL_APPLE_SIGN_IN_KEY: " " }),
        Effect.exit,
      );
      assert.isTrue(Exit.isFailure(empty));
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

describe("DisposableBucket", () => {
  // The props Alchemy resolves for a bucket in `stage` (none: inside the running Worker).
  const propsIn = (stage?: string) => {
    const props = disposableBucketProps({ lifecycleRules: [] });
    return stage === undefined ? props : props.pipe(Effect.provideService(Alchemy.Stage, stage));
  };

  it.effect("lets previews, personal stages and alchemy dev delete non-empty buckets", () =>
    Effect.gen(function* () {
      for (const stage of ["pr-12", "live_tuftlord", "dev_tuftlord"]) {
        assert.propertyVal(yield* propsIn(stage), "forceDestroy", true, stage);
      }
    }),
  );

  it.effect("keeps R2's refusal in staging, prod and the running Worker", () =>
    Effect.gen(function* () {
      for (const stage of ["staging", "prod", undefined]) {
        assert.notProperty(yield* propsIn(stage), "forceDestroy", String(stage));
      }
    }),
  );
});

describe("makeOpenApiSpec", () => {
  it("matches the committed openapi.json (run scripts/format to regenerate)", () => {
    assert.strictEqual(committedSpec, `${JSON.stringify(makeOpenApiSpec(), null, 2)}\n`);
  });

  it("lets clients tolerate fields added later", () => {
    assert.notInclude(JSON.stringify(makeOpenApiSpec()), '"additionalProperties":false');
  });

  it("names schemas without namespaces or the Encoded suffix", () => {
    const names = Object.keys(makeOpenApiSpec().components.schemas);
    assert.includeMembers(names, ["Status", "TokenPair", "Me"]);
    for (const name of names) assert.notMatch(name, /\/|Encoded$/);
  });

  it("writes nullable properties as type arrays, which the Swift generator makes optional", () => {
    const spec = makeOpenApiSpec();
    assert.notInclude(JSON.stringify(spec), '{"type":"null"}');
    assert.deepStrictEqual(
      (spec.components.schemas["Me"] as { properties: Record<string, unknown> }).properties[
        "displayName"
      ],
      {
        type: ["string", "null"],
      },
    );

    class Pair extends Schema.Class<Pair>("lil/Pair")({ a: Schema.String }) {}
    const api = HttpApi.make("nullable").add(
      HttpApiGroup.make("g").add(
        HttpApiEndpoint.get("a", "/a", { success: Schema.Struct({ pair: Schema.NullOr(Pair) }) }),
      ),
    );
    assert.throws(() => makeOpenApiSpec(api), /Unsupported nullable schema/);

    const enums = HttpApi.make("enum").add(
      HttpApiGroup.make("g").add(
        HttpApiEndpoint.get("a", "/a", {
          success: Schema.Struct({
            kind: Schema.NullOr(Schema.Literals(["a", "b"])).annotate({ description: "Kind" }),
          }),
        }),
      ),
    );
    const kind = JSON.stringify(makeOpenApiSpec(enums).paths["/a"]?.get?.responses);
    assert.include(kind, '"type":["string","null"]');
    assert.include(kind, '"enum":["a","b",null]');
    assert.include(kind, '"description":"Kind"');
  });

  it("documents query parameters by their decoded schemas", () => {
    const spec = makeOpenApiSpec();
    assert.deepStrictEqual(
      spec.paths["/v1/sync/changes"]?.get?.parameters?.map((parameter) => [
        parameter.name,
        parameter.schema,
      ]),
      [
        ["after", { type: "integer", minimum: 0, maximum: 9007199254740991, default: 0 }],
        ["limit", { type: "integer", minimum: 1, maximum: 5000, default: 1000 }],
      ],
    );
    // Every endpoint with query parameters needs `documentQuery`.
    for (const [path, operations] of Object.entries(spec.paths)) {
      for (const operation of Object.values(operations ?? {})) {
        for (const parameter of (operation as { parameters?: Array<{ schema: object }> })
          .parameters ?? []) {
          assert.notProperty(parameter.schema, "pattern", path);
        }
      }
    }
  });

  it("names grouped operations in camel case", () => {
    const spec = makeOpenApiSpec();
    assert.strictEqual(spec.paths["/v1/auth/refresh"]?.post?.operationId, "authRefresh");
    assert.strictEqual(spec.paths["/v1/me"]?.get?.operationId, "me");
  });

  it("refuses two schemas that would get the same name", () => {
    class A extends Schema.Class<A>("lil/a/Thing")({ a: Schema.String }) {}
    class B extends Schema.Class<B>("lil/b/Thing")({ b: Schema.String }) {}
    const api = HttpApi.make("collide").add(
      HttpApiGroup.make("g")
        .add(HttpApiEndpoint.get("a", "/a", { success: A }))
        .add(HttpApiEndpoint.get("b", "/b", { success: B })),
    );
    assert.throws(() => makeOpenApiSpec(api), /used by both/);
  });
});
