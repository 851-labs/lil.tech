import { assert, layer } from "@effect/vitest";
import { Effect, Option } from "effect";
import { TestClock } from "effect/testing";
import { generateKeyPair } from "jose";
import { AppleSignIn } from "../../src/auth/Apple.ts";
import { ProviderSignIn } from "../../src/auth/ProviderSignIn.ts";
import { AccessTokens } from "../../src/auth/Tokens.ts";
import { Devices } from "../../src/core/Devices.ts";
import { Identities } from "../../src/core/Identities.ts";
import { Users } from "../../src/core/Users.ts";
import { appleIdentityToken, TestAppleSignIn, testAppleKeysControl } from "./TestApple.ts";

// Synthetic identities only (AGENTS.md).
const iPhone = { app: "health-ios", platform: "ios" as const, name: "Test iPhone" };
let nextSubject = 0;
const newSubject = () => `000123.${String(++nextSubject).padStart(32, "0")}.0001`;

const signIn = (subject: string, nonce: string = crypto.randomUUID(), fullName?: object) =>
  Effect.gen(function* () {
    const token = yield* appleIdentityToken({ sub: subject, nonce });
    const identity = yield* (yield* AppleSignIn).verify(token, nonce, fullName);
    const tokens = yield* (yield* ProviderSignIn).signIn(identity, iPhone, null);
    return yield* (yield* AccessTokens).verify(tokens.accessToken);
  });

const invalid = (token: Effect.Effect<string>, nonce: string) =>
  Effect.gen(function* () {
    const error = yield* Effect.flip((yield* AppleSignIn).verify(yield* token, nonce, undefined));
    assert.strictEqual(error._tag, "InvalidIdentityToken");
    return error.message;
  });

layer(TestAppleSignIn)("Sign in with Apple", (it) => {
  it.effect("creates the user and identity on first sign-in, with the name Apple sent", () =>
    Effect.gen(function* () {
      const subject = newSubject();
      const session = yield* signIn(subject, "nonce-1", {
        givenName: "Ada",
        familyName: "Lovelace",
      });
      const user = yield* (yield* Users).findById(session.userId);
      assert.deepStrictEqual(
        Option.map(user, (u) => u.displayName),
        Option.some("Ada Lovelace"),
      );
      const identity = yield* (yield* Identities).find("apple", subject);
      assert.deepStrictEqual(
        Option.map(identity, (i) => [i.userId, i.email, i.emailVerified]),
        Option.some([session.userId, "x7y2@privaterelay.appleid.com", true]),
      );
    }),
  );

  it.effect("signs a returning user in to the same account, on a new device", () =>
    Effect.gen(function* () {
      const subject = newSubject();
      const first = yield* signIn(subject);
      const second = yield* signIn(subject);
      assert.strictEqual(second.userId, first.userId);
      assert.notStrictEqual(second.deviceId, first.deviceId);
      assert.lengthOf(yield* (yield* Identities).listForUser(first.userId), 1);
      assert.lengthOf(yield* (yield* Devices).listForUser(first.userId), 2);
    }),
  );

  it.effect("concurrent first sign-ins end up in one account", () =>
    Effect.gen(function* () {
      const subject = newSubject();
      const [a, b] = yield* Effect.all([signIn(subject), signIn(subject)], {
        concurrency: "unbounded",
      });
      assert.strictEqual(a?.userId, b?.userId);
    }),
  );

  it.effect("rejects a token for another app", () =>
    Effect.gen(function* () {
      const message = yield* invalid(
        appleIdentityToken({ sub: newSubject(), nonce: "n" }, { audience: "com.example.other" }),
        "n",
      );
      assert.include(message, "aud");
    }),
  );

  it.effect("rejects a token from another issuer, or signed with another key", () =>
    Effect.gen(function* () {
      yield* invalid(
        appleIdentityToken({ sub: newSubject(), nonce: "n" }, { issuer: "https://example.com" }),
        "n",
      );
      const { privateKey } = yield* Effect.promise(() => generateKeyPair("RS256"));
      yield* invalid(
        appleIdentityToken({ sub: newSubject(), nonce: "n" }, { key: privateKey }),
        "n",
      );
    }),
  );

  it.effect("rejects an expired token", () =>
    Effect.gen(function* () {
      const token = yield* appleIdentityToken({ sub: newSubject(), nonce: "n" });
      yield* TestClock.adjust("11 minutes");
      const message = yield* invalid(Effect.succeed(token), "n");
      assert.include(message, "exp");
    }),
  );

  it.effect("rejects a nonce that doesn't match the token", () =>
    Effect.gen(function* () {
      const message = yield* invalid(
        appleIdentityToken({ sub: newSubject(), nonce: "the real nonce" }),
        "another nonce",
      );
      assert.include(message, "nonce");
    }),
  );

  it.effect("a token signs in only once, so a captured request can't be replayed", () =>
    Effect.gen(function* () {
      const nonce = crypto.randomUUID();
      const token = yield* appleIdentityToken({ sub: newSubject(), nonce });
      const apple = yield* AppleSignIn;
      yield* apple.verify(token, nonce, undefined);
      const message = yield* invalid(Effect.succeed(token), nonce);
      assert.include(message, "already used");
    }),
  );

  it.effect("names a user who signs in again with the name Apple sent", () =>
    Effect.gen(function* () {
      const subject = newSubject();
      const first = yield* signIn(subject);
      yield* signIn(subject, crypto.randomUUID(), { givenName: "Grace", familyName: "Hopper" });
      // A later name doesn't replace the first one.
      yield* signIn(subject, crypto.randomUUID(), { givenName: "Someone", familyName: "Else" });
      const user = yield* (yield* Users).findById(first.userId);
      assert.deepStrictEqual(
        Option.map(user, (u) => u.displayName),
        Option.some("Grace Hopper"),
      );
    }),
  );

  it.effect("fetches Apple's keys again for a key ID it hasn't seen", () =>
    Effect.gen(function* () {
      const control = testAppleKeysControl;
      control.mode = "staleCache";
      const before = control.freshFetches;
      yield* signIn(newSubject()).pipe(
        Effect.ensuring(Effect.sync(() => (control.mode = "normal"))),
      );
      assert.strictEqual(control.freshFetches, before + 1);
    }),
  );

  it.effect("answers that sign-in is unavailable when Apple's keys can't be fetched", () =>
    Effect.gen(function* () {
      const control = testAppleKeysControl;
      control.mode = "down";
      const nonce = crypto.randomUUID();
      const token = yield* appleIdentityToken({ sub: newSubject(), nonce });
      const error = yield* Effect.flip((yield* AppleSignIn).verify(token, nonce, undefined)).pipe(
        Effect.ensuring(Effect.sync(() => (control.mode = "normal"))),
      );
      assert.strictEqual(error._tag, "SignInUnavailable");
    }),
  );

  it.effect("never links accounts by email", () =>
    Effect.gen(function* () {
      const first = yield* signIn(newSubject());
      const second = yield* signIn(newSubject());
      // Both tokens carry the same email.
      assert.notStrictEqual(first.userId, second.userId);
    }),
  );
});
