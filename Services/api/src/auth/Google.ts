import { Clock, Context, Effect, Layer, Schema } from "effect";
import { createLocalJWKSet, type JSONWebKeySet, type JWTVerifyGetKey, jwtVerify } from "jose";
import { IdentityTokenUses } from "../core/IdentityTokenUses.ts";
import { joseCode, ProviderKeysUnavailable, verificationErrorCodes } from "./Apple.ts";
import { GoogleSignInUnavailable, InvalidIdentityToken } from "./AuthApi.ts";
import type { VerifiedIdentity } from "./ProviderSignIn.ts";
import { sha256Hex } from "./Tokens.ts";

/** Google issues ID tokens under either issuer. */
export const googleIssuers = ["https://accounts.google.com", "accounts.google.com"];

/**
 * The OAuth client IDs of our iOS and macOS apps, which Google puts in the token's audience.
 * Empty until they're registered (851-2538); until then Google sign-in answers 503.
 */
export const googleClientIds: ReadonlyArray<string> = [];

/** Which Google OAuth clients may sign in. */
export class GoogleClients extends Context.Service<GoogleClients, ReadonlyArray<string>>()(
  "lil/api/auth/GoogleClients",
) {
  static readonly layer = Layer.succeed(GoogleClients, googleClientIds);
}

/** Google's token signing keys. */
export class GoogleKeys extends Context.Service<
  GoogleKeys,
  {
    /** The current keys. `fresh` skips any cache, for a key that's newer than the cached ones. */
    readonly keys: (options: {
      readonly fresh: boolean;
    }) => Effect.Effect<JWTVerifyGetKey, ProviderKeysUnavailable>;
  }
>()("lil/api/auth/GoogleKeys") {
  /** Fetched per sign-in through Cloudflare's cache (an hour), like `AppleKeys`. */
  static readonly layer = Layer.succeed(
    GoogleKeys,
    GoogleKeys.of({
      keys: ({ fresh }) =>
        Effect.tryPromise({
          try: async () => {
            const response = await fetch(
              "https://www.googleapis.com/oauth2/v3/certs",
              (fresh
                ? { cache: "no-store" }
                : { cf: { cacheTtl: 3600, cacheEverything: true } }) as RequestInit,
            );
            if (!response.ok) throw new Error(`Google answered ${response.status}`);
            return createLocalJWKSet((await response.json()) as JSONWebKeySet);
          },
          catch: (error) =>
            new ProviderKeysUnavailable({ message: `Google's keys: ${String(error)}` }),
        }),
    }),
  );
}

const GoogleClaims = Schema.Struct({
  sub: Schema.NonEmptyString,
  exp: Schema.Number,
  email: Schema.optionalKey(Schema.String),
  email_verified: Schema.optionalKey(Schema.Boolean),
  name: Schema.optionalKey(Schema.String),
});

/** Verifies Google ID tokens from the apps' native sign-in. */
export class GoogleSignIn extends Context.Service<
  GoogleSignIn,
  {
    /**
     * Verifies an ID token: Google's signature, issuer, audience (our client IDs), expiry and a
     * verified email. Each token signs in once. Fails with `InvalidIdentityToken`, with
     * `GoogleSignInUnavailable` until client IDs are configured, or dies if Google's keys can't
     * be fetched.
     */
    readonly verify: (
      idToken: string,
    ) => Effect.Effect<VerifiedIdentity, InvalidIdentityToken | GoogleSignInUnavailable>;
  }
>()("lil/api/auth/GoogleSignIn") {
  static readonly layer = Layer.effect(
    GoogleSignIn,
    Effect.gen(function* () {
      const googleKeys = yield* GoogleKeys;
      const clients = yield* GoogleClients;
      const tokenUses = yield* IdentityTokenUses;
      const invalid = (message: string) => new InvalidIdentityToken({ message });

      const verifyWith = (idToken: string, fresh: boolean, now: number) =>
        googleKeys.keys({ fresh }).pipe(
          Effect.flatMap((keys) =>
            Effect.tryPromise({
              try: () =>
                jwtVerify(idToken, keys, {
                  issuer: googleIssuers,
                  audience: [...clients],
                  algorithms: ["RS256"],
                  currentDate: new Date(now),
                }),
              catch: (error) => error,
            }),
          ),
        );

      return GoogleSignIn.of({
        verify: Effect.fn("GoogleSignIn.verify")(
          function* (idToken) {
            if (clients.length === 0) {
              return yield* new GoogleSignInUnavailable({
                message: "Google sign-in isn't set up yet",
              });
            }
            const now = yield* Clock.currentTimeMillis;
            const { payload } = yield* verifyWith(idToken, false, now).pipe(
              Effect.catchIf(
                (error) => joseCode(error) === "ERR_JWKS_NO_MATCHING_KEY",
                () => verifyWith(idToken, true, now),
              ),
              Effect.catchIf(
                (error) => verificationErrorCodes.has(joseCode(error) ?? ""),
                (error) => invalid(`The Google ID token isn't valid: ${String(error)}`),
              ),
            );
            const claims = yield* Schema.decodeUnknownEffect(GoogleClaims)(payload).pipe(
              Effect.mapError((error) =>
                invalid(`The Google ID token is incomplete: ${error.message}`),
              ),
            );
            // Google accounts can carry unverified addresses; sign-in requires a verified one.
            if (claims.email === undefined || claims.email_verified !== true) {
              return yield* invalid("The Google account's email isn't verified");
            }
            const firstUse = yield* tokenUses.claim({
              tokenHash: yield* sha256Hex(idToken),
              expiresAt: claims.exp * 1000,
              now,
            });
            if (!firstUse) return yield* invalid("The Google ID token was already used");
            return {
              provider: "google",
              subject: claims.sub,
              email: claims.email,
              emailVerified: true,
              displayName: claims.name ?? null,
            } satisfies VerifiedIdentity;
          },
          Effect.catch((error) =>
            error instanceof InvalidIdentityToken || error instanceof GoogleSignInUnavailable
              ? Effect.fail(error)
              : Effect.die(error),
          ),
        ),
      });
    }),
  );
}
