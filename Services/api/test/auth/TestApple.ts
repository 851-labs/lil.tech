import { Clock, Effect, Layer } from "effect";
import { type JWTPayload, SignJWT } from "jose";
import { AppleKeys, appleAudiences, appleIssuer, AppleSignIn } from "../../src/auth/Apple.ts";
import { ProviderSignIn } from "../../src/auth/ProviderSignIn.ts";
import { sha256Hex } from "../../src/auth/Tokens.ts";
import { TestAuth } from "./TestAuth.ts";
import { makeTestProviderKeys } from "./TestProviderKeys.ts";

// A stand-in for Apple: a key pair generated for the tests, and identity tokens signed with it.

const apple = await makeTestProviderKeys("test-apple-key");

/** Simulates Apple's key endpoint having a stale cache or being down. */
export const testAppleKeysControl = apple.control;

export const TestAppleKeys = Layer.succeed(AppleKeys, apple.keys);

/** Apple sign-in over the test keys and a test database, with `TestAuth`'s services. */
export const TestAppleSignIn = Layer.mergeAll(AppleSignIn.layer, ProviderSignIn.layer).pipe(
  Layer.provideMerge(TestAppleKeys),
  Layer.provideMerge(TestAuth),
);

/** An identity token as Apple would issue it, valid for 10 minutes from the clock's now. */
export const appleIdentityToken = (
  claims: JWTPayload & { readonly nonce: string },
  options: {
    readonly audience?: string;
    readonly issuer?: string;
    readonly key?: Parameters<SignJWT["sign"]>[0];
  } = {},
) =>
  Effect.gen(function* () {
    const now = Math.floor((yield* Clock.currentTimeMillis) / 1000);
    const nonce = yield* sha256Hex(claims.nonce);
    return yield* Effect.promise(() =>
      new SignJWT({
        email: "x7y2@privaterelay.appleid.com",
        email_verified: "true",
        ...claims,
        nonce,
      })
        .setProtectedHeader({ alg: "RS256", kid: apple.kid })
        .setIssuer(options.issuer ?? appleIssuer)
        .setAudience(options.audience ?? appleAudiences[0] ?? "")
        .setIssuedAt(now)
        .setExpirationTime(now + 600)
        .sign(options.key ?? apple.privateKey),
    );
  });
