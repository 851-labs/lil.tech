import { Clock, Context, Effect, Layer, Schema } from "effect";
import { createLocalJWKSet, type JSONWebKeySet, type JWTVerifyGetKey, jwtVerify } from "jose";
import { IdentityTokenUses } from "../core/IdentityTokenUses.ts";
import { InvalidIdentityToken } from "./AuthApi.ts";
import type { VerifiedIdentity } from "./ProviderSignIn.ts";
import { sha256Hex } from "./Tokens.ts";

/** Who issues Sign in with Apple identity tokens. */
export const appleIssuer = "https://appleid.apple.com";

/**
 * The bundle IDs our apps sign in with, which Apple puts in the token's audience. iOS and macOS
 * share one App ID, so a person gets the same Apple user ID in both (851-2538).
 */
export const appleAudiences = ["tech.lil.health"];

/** A provider's signing keys couldn't be fetched. Retrying later can succeed. */
export class ProviderKeysUnavailable extends Schema.TaggedError<ProviderKeysUnavailable>()(
  "ProviderKeysUnavailable",
  { message: Schema.String },
) {}

/** Apple's token signing keys. */
export class AppleKeys extends Context.Service<
  AppleKeys,
  {
    /**
     * The current keys. `fresh` skips any cache, for a token signed with a key that's newer than
     * the cached ones.
     */
    readonly keys: (options: {
      readonly fresh: boolean;
    }) => Effect.Effect<JWTVerifyGetKey, ProviderKeysUnavailable>;
  }
>()("lil/api/auth/AppleKeys") {
  /**
   * Fetched from Apple per sign-in through Cloudflare's cache (an hour). A Worker can't share
   * one request's fetch with another, so the keys aren't kept in memory between requests.
   */
  static readonly layer = Layer.succeed(
    AppleKeys,
    AppleKeys.of({
      keys: ({ fresh }) =>
        Effect.tryPromise({
          try: async () => {
            const response = await fetch(
              "https://appleid.apple.com/auth/keys",
              (fresh
                ? { cache: "no-store" }
                : { cf: { cacheTtl: 3600, cacheEverything: true } }) as RequestInit,
            );
            if (!response.ok) throw new Error(`Apple answered ${response.status}`);
            return createLocalJWKSet((await response.json()) as JSONWebKeySet);
          },
          catch: (error) =>
            new ProviderKeysUnavailable({ message: `Apple's keys: ${String(error)}` }),
        }),
    }),
  );
}

const AppleClaims = Schema.Struct({
  sub: Schema.NonEmptyString,
  nonce: Schema.String,
  exp: Schema.Number,
  email: Schema.optionalKey(Schema.String),
  // Apple sends booleans as either booleans or strings.
  email_verified: Schema.optionalKey(
    Schema.Union([Schema.Boolean, Schema.Literals(["true", "false"])]),
  ),
});

/** `jose` errors that mean the token itself is bad, rather than that verifying it failed. */
const invalidTokenCodes = new Set([
  "ERR_JWT_EXPIRED",
  "ERR_JWT_CLAIM_VALIDATION_FAILED",
  "ERR_JWT_INVALID",
  "ERR_JWS_INVALID",
  "ERR_JWS_SIGNATURE_VERIFICATION_FAILED",
  "ERR_JWKS_NO_MATCHING_KEY",
  "ERR_JWKS_MULTIPLE_MATCHING_KEYS",
  "ERR_JOSE_ALG_NOT_ALLOWED",
  "ERR_JOSE_NOT_SUPPORTED",
]);

const joseCode = (error: unknown) =>
  typeof error === "object" && error !== null && "code" in error ? String(error.code) : undefined;

/** Verifies Sign in with Apple identity tokens. */
export class AppleSignIn extends Context.Service<
  AppleSignIn,
  {
    /**
     * Verifies an identity token: Apple's signature, issuer, audience, expiry and age, and the
     * nonce. The app sends Apple the SHA-256 (hex) of a random `nonce` and us the nonce itself,
     * tying the token to that sign-in. Each token signs in once, so a captured request can't be
     * replayed. Fails with `InvalidIdentityToken`, or dies if Apple's keys can't be fetched.
     */
    readonly verify: (
      identityToken: string,
      nonce: string,
      fullName:
        | { readonly givenName?: string | null; readonly familyName?: string | null }
        | undefined,
    ) => Effect.Effect<VerifiedIdentity, InvalidIdentityToken>;
  }
>()("lil/api/auth/AppleSignIn") {
  static readonly layer = Layer.effect(
    AppleSignIn,
    Effect.gen(function* () {
      const appleKeys = yield* AppleKeys;
      const tokenUses = yield* IdentityTokenUses;
      const invalid = (message: string) => new InvalidIdentityToken({ message });

      const verifyWith = (identityToken: string, fresh: boolean, now: number) =>
        appleKeys.keys({ fresh }).pipe(
          Effect.flatMap((keys) =>
            Effect.tryPromise({
              try: () =>
                jwtVerify(identityToken, keys, {
                  issuer: appleIssuer,
                  audience: appleAudiences,
                  algorithms: ["RS256"],
                  maxTokenAge: "10m",
                  currentDate: new Date(now),
                }),
              catch: (error) => error,
            }),
          ),
        );

      return AppleSignIn.of({
        verify: Effect.fn("AppleSignIn.verify")(
          function* (identityToken, nonce, fullName) {
            const now = yield* Clock.currentTimeMillis;
            // A key ID that isn't in the cached keys may be one Apple just added.
            const { payload } = yield* verifyWith(identityToken, false, now).pipe(
              Effect.catchIf(
                (error) => joseCode(error) === "ERR_JWKS_NO_MATCHING_KEY",
                () => verifyWith(identityToken, true, now),
              ),
              Effect.catchIf(
                (error) => invalidTokenCodes.has(joseCode(error) ?? ""),
                (error) => invalid(`The Apple identity token isn't valid: ${String(error)}`),
              ),
            );
            const claims = yield* Schema.decodeUnknownEffect(AppleClaims)(payload).pipe(
              Effect.mapError((error) =>
                invalid(`The Apple identity token is incomplete: ${error.message}`),
              ),
            );
            if (claims.nonce !== (yield* sha256Hex(nonce))) {
              return yield* invalid("The nonce doesn't match the Apple identity token");
            }
            const firstUse = yield* tokenUses.claim({
              tokenHash: yield* sha256Hex(identityToken),
              expiresAt: claims.exp * 1000,
              now,
            });
            if (!firstUse) return yield* invalid("The Apple identity token was already used");
            const name = [fullName?.givenName, fullName?.familyName].filter(Boolean).join(" ");
            return {
              provider: "apple",
              subject: claims.sub,
              email: claims.email ?? null,
              emailVerified: claims.email_verified === true || claims.email_verified === "true",
              displayName: name === "" ? null : name,
            } satisfies VerifiedIdentity;
          },
          // Anything else (Apple's keys unreachable, the database) is a server error, so the app
          // retries instead of signing in with Apple again and losing the name it sent.
          Effect.catch((error) =>
            error instanceof InvalidIdentityToken ? Effect.fail(error) : Effect.die(error),
          ),
        ),
      });
    }),
  );
}
