import { Context, Effect, Schema } from "effect";
import { HttpServerRequest, HttpServerResponse } from "effect/http";
import { HttpApiMiddleware } from "effect/http-api";

// Rate limits (`docs/DECISIONS.md`). `TooManyRequests` and `SignInRateLimit` are part of the API
// definition. The Worker counts requests with the Workers rate limiting binding.

/** Too many requests; try again in `retryAfterSeconds`. */
export class TooManyRequests extends Schema.TaggedError<TooManyRequests>()(
  "TooManyRequests",
  { retryAfterSeconds: Schema.Int },
  { httpApiStatus: 429 },
) {}

/**
 * The API's limits, each counted per key over `periodSeconds` (10 or 60, as the binding allows).
 * Counting is approximate and per Cloudflare location.
 */
export const rateLimits = {
  /** Sign-in and refresh requests per IP address. They're unauthenticated and create accounts. */
  signIn: { limit: 60, periodSeconds: 60 },
  /** Authenticated requests per user. */
  user: { limit: 600, periodSeconds: 60 },
} as const satisfies Record<string, { readonly limit: number; readonly periodSeconds: 10 | 60 }>;

export type RateLimitName = keyof typeof rateLimits;

/** Counts a request for `key`, answering whether it's within the limit. */
export type RateLimitCounter = (key: string) => Effect.Effect<boolean, unknown>;

export class RateLimits extends Context.Service<
  RateLimits,
  {
    /** Counts a request against `limit` for `key`, failing once the key is over it. */
    readonly check: (limit: RateLimitName, key: string) => Effect.Effect<void, TooManyRequests>;
  }
>()("lil/api/RateLimits") {
  /**
   * Rate limits from a counter per limit. A counter that fails lets the request through: an
   * outage of the binding shouldn't take the API down with it.
   */
  static readonly make = (counters: Record<RateLimitName, RateLimitCounter>) =>
    RateLimits.of({
      check: (limit, key) =>
        counters[limit](key).pipe(
          Effect.catch((error) =>
            Effect.logWarning(`Rate limit ${limit} failed; allowing the request`, error).pipe(
              Effect.as(true),
            ),
          ),
          Effect.flatMap((allowed) =>
            allowed
              ? Effect.void
              : Effect.fail(
                  new TooManyRequests({ retryAfterSeconds: rateLimits[limit].periodSeconds }),
                ),
          ),
        ),
    });

  /** No limits, e.g. for tests that aren't about them. */
  static readonly unlimited = RateLimits.make({
    signIn: () => Effect.succeed(true),
    user: () => Effect.succeed(true),
  });
}

/** Limits sign-in and refresh requests per IP address (`rateLimits.signIn`). */
export class SignInRateLimit extends HttpApiMiddleware.Service<SignInRateLimit>()(
  "lil/api/SignInRateLimit",
  { error: TooManyRequests },
) {}

/**
 * Counts a sign-in or refresh against its IP address's limit. The address is Cloudflare's
 * `cf-connecting-ip`, which clients can't set. Only local runs and tests go without one.
 */
export const checkSignInRateLimit = (limits: RateLimits["Service"]) =>
  Effect.gen(function* () {
    const address = (yield* HttpServerRequest.HttpServerRequest).headers["cf-connecting-ip"];
    if (address !== undefined) yield* limits.check("signIn", address);
  });

/** A `TooManyRequests` response, for routes outside the `HttpApi`. */
export const tooManyRequests = (error: TooManyRequests) =>
  HttpServerResponse.jsonUnsafe(
    { _tag: error._tag, retryAfterSeconds: error.retryAfterSeconds },
    { status: 429, headers: { "retry-after": String(error.retryAfterSeconds) } },
  );

/**
 * A namespace ID for one of a stage's limits. Namespaces are per account, and bindings with the
 * same ID share counters, so each stage gets its own (a hash of its name).
 */
export const rateLimitNamespaceId = (stage: string, limit: RateLimitName) => {
  // FNV-1a, kept well below 2^31 with room for one digit per limit.
  let hash = 0x811c9dc5;
  for (const character of stage) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  const index = Object.keys(rateLimits).indexOf(limit);
  return String(((hash % 100_000_000) + 1) * 10 + index);
};
