import { readFileSync } from "node:fs";
import { assert, describe, it, layer } from "@effect/vitest";
import { Effect, Layer, Option, Redacted } from "effect";
import { TestClock } from "effect/testing";
import { GoogleClients, googleClientIds, GoogleSignIn } from "../../src/auth/Google.ts";
import { GoogleWebClient } from "../../src/auth/GoogleWeb.ts";
import { ProviderSignIn } from "../../src/auth/ProviderSignIn.ts";
import { AccessTokens } from "../../src/auth/Tokens.ts";
import { Identities } from "../../src/core/Identities.ts";
import { Users } from "../../src/core/Users.ts";
import {
  googleIdToken,
  TestGoogleKeys,
  TestGoogleSignIn,
  testGoogleClients,
  testGoogleKeysControl,
} from "./TestGoogle.ts";
import { TestAuth } from "./TestAuth.ts";

// Synthetic identities only (AGENTS.md).
const mac = { app: "health-mac", platform: "macos" as const, name: null };
let nextSubject = 0;
const newSubject = () => `1${String(++nextSubject).padStart(20, "0")}`;

const signIn = (claims: Record<string, unknown>) =>
  Effect.gen(function* () {
    const nonce = crypto.randomUUID();
    const token = yield* googleIdToken({ ...claims, nonce });
    const identity = yield* (yield* GoogleSignIn).verify(token, nonce);
    const tokens = yield* (yield* ProviderSignIn).signIn(identity, mac, null);
    return yield* (yield* AccessTokens).verify(tokens.accessToken);
  });

const rejected = (token: Effect.Effect<string>, nonce = "n") =>
  Effect.gen(function* () {
    const error = yield* Effect.flip((yield* GoogleSignIn).verify(yield* token, nonce));
    assert.strictEqual(error._tag, "InvalidIdentityToken");
    return error.message;
  });

layer(TestGoogleSignIn)("Sign in with Google", (it) => {
  it.effect("creates the user and identity on first sign-in", () =>
    Effect.gen(function* () {
      const subject = newSubject();
      const session = yield* signIn({ sub: subject });
      const user = yield* (yield* Users).findById(session.userId);
      assert.deepStrictEqual(
        Option.map(user, (u) => u.displayName),
        Option.some("Ada"),
      );
      const identity = yield* (yield* Identities).find("google", subject);
      assert.deepStrictEqual(
        Option.map(identity, (i) => [i.userId, i.email, i.emailVerified]),
        Option.some([session.userId, "ada@example.com", true]),
      );
    }),
  );

  it.effect("signs a returning user in to the same account", () =>
    Effect.gen(function* () {
      const subject = newSubject();
      const first = yield* signIn({ sub: subject });
      const second = yield* signIn({ sub: subject });
      assert.strictEqual(second.userId, first.userId);
    }),
  );

  it.effect("accepts both of Google's issuers", () =>
    Effect.gen(function* () {
      const identity = yield* (yield* GoogleSignIn).verify(
        yield* googleIdToken({ sub: newSubject(), nonce: "n" }, { issuer: "accounts.google.com" }),
        "n",
      );
      assert.strictEqual(identity.provider, "google");
    }),
  );

  it.effect("rejects a token for another client", () =>
    Effect.gen(function* () {
      const message = yield* rejected(
        googleIdToken(
          { sub: newSubject(), nonce: "n" },
          { audience: "other.apps.googleusercontent.com" },
        ),
      );
      assert.include(message, "aud");
    }),
  );

  it.effect("rejects an expired token", () =>
    Effect.gen(function* () {
      const token = yield* googleIdToken({ sub: newSubject(), nonce: "n" });
      yield* TestClock.adjust("61 minutes");
      const message = yield* rejected(Effect.succeed(token));
      assert.include(message, "exp");
    }),
  );

  it.effect("rejects an account whose email isn't verified, or has none", () =>
    Effect.gen(function* () {
      const unverified = yield* rejected(
        googleIdToken({ sub: newSubject(), nonce: "n", email_verified: false }),
      );
      assert.include(unverified, "verified");
      yield* rejected(googleIdToken({ sub: newSubject(), nonce: "n", email: undefined }));
    }),
  );

  it.effect("a token signs in only once", () =>
    Effect.gen(function* () {
      const token = yield* googleIdToken({ sub: newSubject(), nonce: "n" });
      yield* (yield* GoogleSignIn).verify(token, "n");
      const message = yield* rejected(Effect.succeed(token));
      assert.include(message, "already used");
    }),
  );

  it.effect("rejects a nonce that doesn't match the token", () =>
    Effect.gen(function* () {
      const message = yield* rejected(
        googleIdToken({ sub: newSubject(), nonce: "the real nonce" }),
        "another nonce",
      );
      assert.include(message, "nonce");
    }),
  );

  it.effect("accepts a token for our server client that one of our apps requested", () =>
    Effect.gen(function* () {
      const server = testGoogleClients.server[0] ?? "";
      const app = testGoogleClients.apps[0] ?? "";
      const identity = yield* (yield* GoogleSignIn).verify(
        yield* googleIdToken({ sub: newSubject(), nonce: "n", azp: app }, { audience: server }),
        "n",
      );
      assert.strictEqual(identity.provider, "google");
      const message = yield* rejected(
        googleIdToken(
          { sub: newSubject(), nonce: "n", azp: "other.apps.googleusercontent.com" },
          { audience: server },
        ),
      );
      assert.include(message, "another app");
    }),
  );

  it.effect("fetches Google's keys again for a key ID it hasn't seen", () =>
    Effect.gen(function* () {
      const control = testGoogleKeysControl;
      control.mode = "staleCache";
      const before = control.freshFetches;
      yield* signIn({ sub: newSubject() }).pipe(
        Effect.ensuring(Effect.sync(() => (control.mode = "normal"))),
      );
      assert.strictEqual(control.freshFetches, before + 1);
    }),
  );

  it.effect("answers that sign-in is unavailable when Google's keys can't be fetched", () =>
    Effect.gen(function* () {
      const control = testGoogleKeysControl;
      control.mode = "down";
      const token = yield* googleIdToken({ sub: newSubject(), nonce: "n" });
      const error = yield* Effect.flip((yield* GoogleSignIn).verify(token, "n")).pipe(
        Effect.ensuring(Effect.sync(() => (control.mode = "normal"))),
      );
      assert.strictEqual(error._tag, "SignInUnavailable");
    }),
  );
});

describe("Sign in with Google without client IDs", () => {
  layer(
    GoogleSignIn.layer.pipe(
      Layer.provide(Layer.succeed(GoogleClients, { apps: [], web: [], server: [] })),
      Layer.provide(TestGoogleKeys),
      Layer.provideMerge(TestAuth),
    ),
  )((it) => {
    it.effect("answers that it isn't available", () =>
      Effect.gen(function* () {
        const token = yield* googleIdToken({ sub: newSubject(), nonce: "n" });
        const error = yield* Effect.flip((yield* GoogleSignIn).verify(token, "n"));
        assert.strictEqual(error._tag, "SignInUnavailable");
      }),
    );
  });
});

describe("googleClientIds", () => {
  // The apps read their client ID from their Info.plist (`GIDClientID`), named after the target
  // (`Apps/LilHealth/<Target>-Info.plist`). A copy that differs from the server's would make Google
  // sign-in fail for that app.
  it.each(["LilHealth", "LilHealthiOS"])("lists the client ID in %s-Info.plist", (app) => {
    const plist = readFileSync(
      new URL(`../../../../Apps/LilHealth/${app}-Info.plist`, import.meta.url),
      "utf8",
    );
    const clientId = /<key>GIDClientID<\/key>\s*<string>([^<]+)<\/string>/.exec(plist)?.[1];
    assert.include(googleClientIds.apps, clientId);
  });
});

describe("The authorization page's Google client", () => {
  const client = (clients: GoogleClients["Service"], secret: Option.Option<string>) =>
    GoogleWebClient.use((web) => Effect.succeed(web)).pipe(
      Effect.provide(
        GoogleWebClient.layer({ clientSecret: Option.map(secret, Redacted.make) }).pipe(
          Layer.provide(Layer.succeed(GoogleClients, clients)),
        ),
      ),
    );

  it.effect("is set up only with a web client and its secret", () =>
    Effect.gen(function* () {
      const both = yield* client(testGoogleClients, Option.some("secret"));
      assert.deepStrictEqual(both.clientId, Option.some(testGoogleClients.web[0] ?? ""));
      const noSecret = yield* client(testGoogleClients, Option.none());
      assert.isTrue(Option.isNone(noSecret.clientId));
      const error = yield* Effect.flip(
        noSecret.redeem({ code: "c", codeVerifier: "v", redirectUri: "https://x/cb" }),
      );
      assert.strictEqual(error._tag, "GoogleCodeRedemptionFailed");
      const noClient = yield* client({ ...testGoogleClients, web: [] }, Option.some("secret"));
      assert.isTrue(Option.isNone(noClient.clientId));
    }),
  );
});
