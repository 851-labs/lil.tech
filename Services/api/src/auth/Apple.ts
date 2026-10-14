import { Clock, Context, Effect, Layer, Schema } from "effect";
import { createRemoteJWKSet, type JWTVerifyGetKey, jwtVerify } from "jose";
import { InvalidIdentityToken } from "./AuthApi.ts";
import type { VerifiedIdentity } from "./ProviderSignIn.ts";

/** Who issues Sign in with Apple identity tokens. */
export const appleIssuer = "https://appleid.apple.com";

/**
 * The bundle IDs our apps sign in with, which Apple puts in the token's audience. iOS and macOS
 * share one App ID, so a person gets the same Apple user ID in both (851-2538).
 */
export const appleAudiences = ["tech.lil.health"];

/** Apple's token signing keys. Live: fetched from Apple and cached by `jose`. */
export class AppleKeys extends Context.Service<AppleKeys, JWTVerifyGetKey>()(
  "lil/api/auth/AppleKeys",
) {
  static readonly layer = Layer.sync(AppleKeys, () =>
    createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys")),
  );
}

const AppleClaims = Schema.Struct({
  sub: Schema.NonEmptyString,
  nonce: Schema.String,
  email: Schema.optionalKey(Schema.String),
  // Apple sends booleans as either booleans or strings.
  email_verified: Schema.optionalKey(
    Schema.Union([Schema.Boolean, Schema.Literals(["true", "false"])]),
  ),
});

const sha256Hex = (value: string) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).pipe(
    Effect.map((digest) =>
      Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join(""),
    ),
  );

/**
 * Verifies a Sign in with Apple identity token: Apple's signature, issuer, audience, expiry, and
 * the nonce. The app sends Apple the SHA-256 (hex) of a random `nonce` and us the nonce itself,
 * so a token can't be replayed in another sign-in.
 */
export const verifyAppleToken = Effect.fn("verifyAppleToken")(function* (
  identityToken: string,
  nonce: string,
  fullName: { readonly givenName?: string | null; readonly familyName?: string | null } | undefined,
) {
  const keys = yield* AppleKeys;
  const now = yield* Clock.currentTimeMillis;
  const invalid = (message: string) => new InvalidIdentityToken({ message });
  const { payload } = yield* Effect.tryPromise({
    try: () =>
      jwtVerify(identityToken, keys, {
        issuer: appleIssuer,
        audience: appleAudiences,
        currentDate: new Date(now),
      }),
    catch: (error) => invalid(`The Apple identity token isn't valid: ${String(error)}`),
  });
  const claims = yield* Schema.decodeUnknownEffect(AppleClaims)(payload).pipe(
    Effect.mapError((error) => invalid(`The Apple identity token is incomplete: ${error.message}`)),
  );
  if (claims.nonce !== (yield* sha256Hex(nonce))) {
    return yield* invalid("The nonce doesn't match the Apple identity token");
  }
  const name = [fullName?.givenName, fullName?.familyName].filter(Boolean).join(" ");
  return {
    provider: "apple",
    subject: claims.sub,
    email: claims.email ?? null,
    emailVerified: claims.email_verified === true || claims.email_verified === "true",
    displayName: name === "" ? null : name,
  } satisfies VerifiedIdentity;
});
