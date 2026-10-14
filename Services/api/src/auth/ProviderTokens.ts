import { Effect, Schema } from "effect";
import {
  createLocalJWKSet,
  type JSONWebKeySet,
  type JWTPayload,
  type JWTVerifyGetKey,
  jwtVerify,
} from "jose";
import type { IdentityTokenUses } from "../core/IdentityTokenUses.ts";
import { InvalidIdentityToken, SignInUnavailable } from "./AuthApi.ts";
import { sha256Hex } from "./Tokens.ts";

// Verifying sign-in providers' ID tokens (Apple, Google): fetching their keys, checking a token,
// its nonce, and that it's used once.

/** A provider's signing keys couldn't be fetched. Retrying later can succeed. */
export class ProviderKeysUnavailable extends Schema.TaggedError<ProviderKeysUnavailable>()(
  "ProviderKeysUnavailable",
  { message: Schema.String },
) {}

/** A provider's token signing keys. */
export interface ProviderKeys {
  /**
   * The current keys. `fresh` skips the cache, for a token signed with a key that's newer than
   * the cached ones.
   */
  readonly keys: (options: {
    readonly fresh: boolean;
  }) => Effect.Effect<JWTVerifyGetKey, ProviderKeysUnavailable>;
}

/** How often, at most, each Worker isolate fetches a provider's keys past the cache. */
const freshFetchInterval = 60 * 1000;

/**
 * A provider's keys, fetched per sign-in through Cloudflare's cache (an hour). A Worker can't
 * share one request's fetch with another, so they aren't kept in memory between requests. Fresh
 * fetches happen at most once a minute, so tokens with made-up key IDs can't make us hammer the
 * provider.
 */
export const fetchedProviderKeys = (provider: string, url: string): ProviderKeys => {
  let lastFreshFetch = Number.NEGATIVE_INFINITY;
  return {
    keys: ({ fresh }) =>
      Effect.suspend(() => {
        const now = Date.now();
        const skipCache = fresh && now - lastFreshFetch >= freshFetchInterval;
        if (skipCache) lastFreshFetch = now;
        return Effect.tryPromise({
          try: async () => {
            const response = await fetch(
              url,
              (skipCache
                ? { cache: "no-store" }
                : { cf: { cacheTtl: 3600, cacheEverything: true } }) as RequestInit,
            );
            if (!response.ok) throw new Error(`${provider} answered ${response.status}`);
            return createLocalJWKSet((await response.json()) as JSONWebKeySet);
          },
          catch: (error) =>
            new ProviderKeysUnavailable({ message: `${provider}'s keys: ${String(error)}` }),
        });
      }),
  };
};

/** `jose` errors that mean the token itself is bad, rather than that verifying it failed. */
const invalidTokenCodes: ReadonlySet<string> = new Set([
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

/**
 * Verifies a provider's ID token: its signature (refetching the keys once for an unknown key ID),
 * `RS256`, issuer, audience, expiry and age, then decodes its claims. Fails with
 * `InvalidIdentityToken` for a bad token and `SignInUnavailable` when the keys can't be fetched.
 */
export const verifyProviderToken = <A>(input: {
  readonly provider: string;
  readonly token: string;
  readonly keys: ProviderKeys;
  readonly issuer: string | ReadonlyArray<string>;
  readonly audience: ReadonlyArray<string>;
  readonly maxTokenAge: string;
  readonly now: number;
  readonly claims: Schema.Decoder<A, never>;
}): Effect.Effect<A, InvalidIdentityToken | SignInUnavailable> => {
  const invalid = (message: string) =>
    new InvalidIdentityToken({ message: `The ${input.provider} token ${message}` });
  const verifyWith = (fresh: boolean) =>
    input.keys.keys({ fresh }).pipe(
      Effect.flatMap((keys) =>
        Effect.tryPromise({
          try: () =>
            jwtVerify(input.token, keys, {
              issuer: input.issuer as string | Array<string>,
              audience: input.audience as Array<string>,
              algorithms: ["RS256"],
              maxTokenAge: input.maxTokenAge,
              currentDate: new Date(input.now),
            }),
          catch: (error) => error,
        }),
      ),
    );
  return verifyWith(false).pipe(
    Effect.catchIf(
      (error) => joseCode(error) === "ERR_JWKS_NO_MATCHING_KEY",
      () => verifyWith(true),
    ),
    Effect.map(({ payload }: { payload: JWTPayload }) => payload),
    Effect.flatMap((payload) =>
      Schema.decodeUnknownEffect(input.claims)(payload).pipe(
        Effect.mapError((error) => invalid(`is incomplete: ${error.message}`)),
      ),
    ),
    Effect.catch((error): Effect.Effect<never, InvalidIdentityToken | SignInUnavailable> => {
      if (error instanceof InvalidIdentityToken) return Effect.fail(error);
      if (error instanceof ProviderKeysUnavailable) {
        return Effect.fail(new SignInUnavailable({ message: error.message }));
      }
      if (invalidTokenCodes.has(joseCode(error) ?? "")) {
        return Effect.fail(invalid(`isn't valid: ${String(error)}`));
      }
      return Effect.die(error);
    }),
  );
};

/**
 * Checks that a token's `nonce` claim is the SHA-256 (hex) of the nonce the app sent us, which
 * ties the token to the app's sign-in: the app asked the provider for a token with the hash.
 */
export const checkNonce = (provider: string, claim: string, nonce: string) =>
  sha256Hex(nonce).pipe(
    Effect.flatMap((hash) =>
      hash === claim
        ? Effect.void
        : Effect.fail(
            new InvalidIdentityToken({ message: `The nonce doesn't match the ${provider} token` }),
          ),
    ),
  );

/** Records a token's use so it signs in only once, and fails if it already did. */
export const useOnce = (
  tokenUses: IdentityTokenUses["Service"],
  provider: string,
  token: string,
  input: { readonly expiresAt: number; readonly now: number },
) =>
  sha256Hex(token).pipe(
    Effect.flatMap((tokenHash) => tokenUses.claim({ tokenHash, ...input })),
    Effect.orDie,
    Effect.flatMap((firstUse) =>
      firstUse
        ? Effect.void
        : Effect.fail(
            new InvalidIdentityToken({ message: `The ${provider} token was already used` }),
          ),
    ),
  );
