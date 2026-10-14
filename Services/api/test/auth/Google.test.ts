import { assert, describe, layer } from "@effect/vitest";
import { Effect, Layer, Option } from "effect";
import { TestClock } from "effect/testing";
import { GoogleClients, GoogleSignIn } from "../../src/auth/Google.ts";
import { ProviderSignIn } from "../../src/auth/ProviderSignIn.ts";
import { AccessTokens } from "../../src/auth/Tokens.ts";
import { Identities } from "../../src/core/Identities.ts";
import { Users } from "../../src/core/Users.ts";
import { googleIdToken, TestGoogleKeys, TestGoogleSignIn } from "./TestGoogle.ts";
import { TestAuth } from "./TestAuth.ts";

// Synthetic identities only (AGENTS.md).
const mac = { app: "health-mac", platform: "macos" as const, name: null };
let nextSubject = 0;
const newSubject = () => `1${String(++nextSubject).padStart(20, "0")}`;

const signIn = (claims: Record<string, unknown>) =>
  Effect.gen(function* () {
    const identity = yield* (yield* GoogleSignIn).verify(yield* googleIdToken(claims));
    const tokens = yield* (yield* ProviderSignIn).signIn(identity, mac);
    return yield* (yield* AccessTokens).verify(tokens.accessToken);
  });

const rejected = (token: Effect.Effect<string>) =>
  Effect.gen(function* () {
    const error = yield* Effect.flip((yield* GoogleSignIn).verify(yield* token));
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
        yield* googleIdToken({ sub: newSubject() }, { issuer: "accounts.google.com" }),
      );
      assert.strictEqual(identity.provider, "google");
    }),
  );

  it.effect("rejects a token for another client", () =>
    Effect.gen(function* () {
      const message = yield* rejected(
        googleIdToken({ sub: newSubject() }, { audience: "other.apps.googleusercontent.com" }),
      );
      assert.include(message, "aud");
    }),
  );

  it.effect("rejects an expired token", () =>
    Effect.gen(function* () {
      const token = yield* googleIdToken({ sub: newSubject() });
      yield* TestClock.adjust("61 minutes");
      const message = yield* rejected(Effect.succeed(token));
      assert.include(message, "exp");
    }),
  );

  it.effect("rejects an account whose email isn't verified, or has none", () =>
    Effect.gen(function* () {
      const unverified = yield* rejected(
        googleIdToken({ sub: newSubject(), email_verified: false }),
      );
      assert.include(unverified, "verified");
      yield* rejected(googleIdToken({ sub: newSubject(), email: undefined }));
    }),
  );

  it.effect("a token signs in only once", () =>
    Effect.gen(function* () {
      const token = yield* googleIdToken({ sub: newSubject() });
      yield* (yield* GoogleSignIn).verify(token);
      const message = yield* rejected(Effect.succeed(token));
      assert.include(message, "already used");
    }),
  );
});

describe("Sign in with Google before client IDs are registered", () => {
  layer(
    GoogleSignIn.layer.pipe(
      Layer.provide(Layer.succeed(GoogleClients, [])),
      Layer.provideMerge(TestGoogleKeys.pipe(Layer.provide(Layer.empty))),
      Layer.provideMerge(TestAuth),
    ),
  )((it) => {
    it.effect("answers that it isn't available", () =>
      Effect.gen(function* () {
        const token = yield* googleIdToken({ sub: newSubject() });
        const error = yield* Effect.flip((yield* GoogleSignIn).verify(token));
        assert.strictEqual(error._tag, "GoogleSignInUnavailable");
      }),
    );
  });
});
