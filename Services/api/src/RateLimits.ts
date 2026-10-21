import { Context, Effect, Schema } from "effect";
import { HttpServerRequest, HttpServerResponse } from "effect/http";
import { HttpApiMiddleware } from "effect/http-api";

// Rate limits (`docs/DECISIONS.md`). `TooManyRequests` and `AddressRateLimit` are part of the API
// definition. The Worker counts requests with the Workers rate limiting binding.

/** Too many requests; try again in `retryAfterSeconds`. */
export class TooManyRequests extends Schema.TaggedError<TooManyRequests>()(
  "TooManyRequests",
  { retryAfterSeconds: Schema.Int },
  { httpApiStatus: 429 },
) {}

/**
 * The API's limits, each counted per key over `periodSeconds` (10 or 60, as the binding allows).
 * Counting is approximate and per Cloudflare location. `namespace` numbers a limit within its
 * stage's namespace IDs, so it must never change or be reused.
 */
export const rateLimits = {
  /** Sign-ins per IP address. They're unauthenticated and create accounts. */
  signIn: { namespace: 1, limit: 60, periodSeconds: 60 },
  /** Authenticated requests per user. */
  user: { namespace: 2, limit: 600, periodSeconds: 60 },
  /**
   * Refreshes per IP address. Separate from sign-ins and higher, since every device behind an
   * address (e.g. carrier NAT) refreshes about every 15 minutes.
   */
  refresh: { namespace: 3, limit: 600, periodSeconds: 60 },
  /**
   * Dynamic client registrations (`POST /oauth/register`) per IP address. High, because hosted
   * agents register from shared egress ranges: Claude registers a client per connection.
   */
  clientRegistration: { namespace: 4, limit: 300, periodSeconds: 60 },
  /**
   * Agents' token requests (`POST /oauth/token`): per grant for refreshes, per client for code
   * exchanges. Not per IP address, since hosted agents (Claude, ChatGPT) refresh from shared
   * egress ranges.
   */
  agentToken: { namespace: 5, limit: 60, periodSeconds: 60 },
} as const satisfies Record<
  string,
  { readonly namespace: number; readonly limit: number; readonly periodSeconds: 10 | 60 }
>;

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
    refresh: () => Effect.succeed(true),
    clientRegistration: () => Effect.succeed(true),
    agentToken: () => Effect.succeed(true),
  });
}

/** Limits a request per IP address: refreshes by `rateLimits.refresh`, others by `signIn`. */
export class AddressRateLimit extends HttpApiMiddleware.Service<AddressRateLimit>()(
  "lil/api/AddressRateLimit",
  { error: TooManyRequests },
) {}

/**
 * The key for an address. IPv4 is the address itself. IPv6 is its /64, since one client usually
 * has a whole /64 and could otherwise use a new address for every request.
 */
export const addressKey = (address: string) => {
  if (!address.includes(":")) return address;
  // An IPv4 address mapped into IPv6 (`::ffff:192.0.2.1`).
  const last = address.slice(address.lastIndexOf(":") + 1);
  if (last.includes(".")) return last;
  const [head = "", tail] = address.split("::");
  const left = head === "" ? [] : head.split(":");
  const right = tail === undefined || tail === "" ? [] : tail.split(":");
  const groups =
    tail === undefined
      ? left
      : [...left, ...Array<string>(8 - left.length - right.length).fill("0"), ...right];
  const prefix = groups
    .slice(0, 4)
    .map((group) => Number.parseInt(group, 16).toString(16))
    .join(":");
  return `${prefix}::/64`;
};

/**
 * Counts a request against its IP address's `limit`. The address is Cloudflare's
 * `cf-connecting-ip`, which clients can't set. Only local runs and tests go without one.
 */
export const checkAddressRateLimit = (limits: RateLimits["Service"], limit: RateLimitName) =>
  Effect.gen(function* () {
    const address = (yield* HttpServerRequest.HttpServerRequest).headers["cf-connecting-ip"];
    if (address !== undefined) yield* limits.check(limit, addressKey(address));
  });

/** A `TooManyRequests` response, for routes outside the `HttpApi`. */
export const tooManyRequests = (error: TooManyRequests) =>
  HttpServerResponse.schemaJson(TooManyRequests)(error, {
    status: 429,
    headers: { "retry-after": String(error.retryAfterSeconds) },
  }).pipe(Effect.orDie);

/**
 * A namespace ID for one of a stage's limits. Namespaces are per account, and bindings with the
 * same ID share counters, so each stage gets its own (a hash of its name).
 */
export const rateLimitNamespaceId = (stage: string, limit: RateLimitName) => {
  // FNV-1a, kept below 2^31 with two digits for the limit's number.
  let hash = 0x811c9dc5;
  for (const character of stage) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return String(((hash % 10_000_000) + 1) * 100 + rateLimits[limit].namespace);
};
