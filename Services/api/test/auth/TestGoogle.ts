import { Clock, Effect, Layer } from "effect";
import { createLocalJWKSet, exportJWK, generateKeyPair, type JWTPayload, SignJWT } from "jose";
import { GoogleClients, GoogleKeys, GoogleSignIn } from "../../src/auth/Google.ts";
import { ProviderSignIn } from "../../src/auth/ProviderSignIn.ts";
import { TestAuth } from "./TestAuth.ts";

// A stand-in for Google: a key pair generated for the tests, and ID tokens signed with it.

const { privateKey, publicKey } = await generateKeyPair("RS256");
const kid = "test-google-key";
const keySet = createLocalJWKSet({
  keys: [{ ...(await exportJWK(publicKey)), kid, alg: "RS256" }],
});

/** A made-up OAuth client ID for the test apps. */
export const testGoogleClientId = "000000000000-test.apps.googleusercontent.com";

export const TestGoogleKeys = Layer.mergeAll(
  Layer.succeed(GoogleKeys, GoogleKeys.of({ keys: () => Effect.succeed(keySet) })),
  Layer.succeed(GoogleClients, [testGoogleClientId]),
);

/** Google sign-in over the test keys and a test database, with `TestAuth`'s services. */
export const TestGoogleSignIn = Layer.mergeAll(GoogleSignIn.layer, ProviderSignIn.layer).pipe(
  Layer.provideMerge(TestGoogleKeys),
  Layer.provideMerge(TestAuth),
);

/** An ID token as Google would issue it, valid for an hour from the clock's now. */
export const googleIdToken = (
  claims: JWTPayload,
  options: { readonly audience?: string; readonly issuer?: string } = {},
) =>
  Effect.gen(function* () {
    const now = Math.floor((yield* Clock.currentTimeMillis) / 1000);
    return yield* Effect.promise(() =>
      new SignJWT({
        email: "ada@example.com",
        email_verified: true,
        name: "Ada",
        // Real tokens differ per sign-in; without this, two at the same instant would be identical.
        jti: crypto.randomUUID(),
        ...claims,
      })
        .setProtectedHeader({ alg: "RS256", kid })
        .setIssuer(options.issuer ?? "https://accounts.google.com")
        .setAudience(options.audience ?? testGoogleClientId)
        .setIssuedAt(now)
        .setExpirationTime(now + 3600)
        .sign(privateKey),
    );
  });
