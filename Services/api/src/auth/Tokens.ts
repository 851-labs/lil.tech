import { Clock, Context, Effect, Layer, Redacted, Schema } from "effect";
import { jwtVerify, SignJWT } from "jose";
import { AccessTokenClaims } from "./AuthApi.ts";

/** How long an access token is valid. Short, because access tokens can't be revoked. */
export const accessTokenLifetimeMs = 15 * 60 * 1000;
/** How long a refresh token is valid. Each rotation starts a new period. */
export const refreshTokenLifetimeMs = 90 * 24 * 60 * 60 * 1000;

const issuer = "https://api.lil.tech";
const audience = "lil";

/** The key that signs access tokens. Each stage has its own (see `Worker.ts`). */
export class SessionKey extends Context.Service<SessionKey, Redacted.Redacted<string>>()(
  "lil/api/auth/SessionKey",
) {}

export class InvalidAccessToken extends Schema.TaggedError<InvalidAccessToken>()(
  "InvalidAccessToken",
  { reason: Schema.String },
) {}

export class AccessTokens extends Context.Service<
  AccessTokens,
  {
    readonly sign: (
      claims: AccessTokenClaims,
    ) => Effect.Effect<{ readonly token: string; readonly expiresAt: number }>;
    readonly verify: (token: string) => Effect.Effect<AccessTokenClaims, InvalidAccessToken>;
    /** `verify`, plus when the token expires (Unix milliseconds). */
    readonly verifyWithExpiry: (
      token: string,
    ) => Effect.Effect<
      { readonly claims: AccessTokenClaims; readonly expiresAt: number },
      InvalidAccessToken
    >;
  }
>()("lil/api/auth/AccessTokens") {
  static readonly layer = Layer.effect(
    AccessTokens,
    Effect.gen(function* () {
      const secret = new TextEncoder().encode(Redacted.value(yield* SessionKey));
      const decodeClaims = Schema.decodeUnknownEffect(AccessTokenClaims);
      const verifyWithExpiry = Effect.fn("AccessTokens.verify")(function* (token: string) {
        const now = yield* Clock.currentTimeMillis;
        const { payload } = yield* Effect.tryPromise({
          try: () =>
            jwtVerify(token, secret, {
              issuer,
              audience,
              algorithms: ["HS256"],
              currentDate: new Date(now),
            }),
          catch: (error) => new InvalidAccessToken({ reason: String(error) }),
        });
        const claims = yield* decodeClaims({
          userId: payload.sub,
          deviceId: payload["dev"],
          sessionId: payload["sid"],
        }).pipe(Effect.mapError((error) => new InvalidAccessToken({ reason: error.message })));
        return { claims, expiresAt: (payload.exp ?? 0) * 1000 };
      });
      return AccessTokens.of({
        sign: Effect.fn("AccessTokens.sign")(function* (claims) {
          const now = yield* Clock.currentTimeMillis;
          // JWT times are whole seconds, so the reported expiry is rounded down to match `exp`.
          const expiresAt = Math.floor((now + accessTokenLifetimeMs) / 1000) * 1000;
          const token = yield* Effect.promise(() =>
            new SignJWT({ dev: claims.deviceId, sid: claims.sessionId })
              .setProtectedHeader({ alg: "HS256" })
              .setSubject(claims.userId)
              .setIssuer(issuer)
              .setAudience(audience)
              .setIssuedAt(Math.floor(now / 1000))
              .setExpirationTime(Math.floor(expiresAt / 1000))
              .sign(secret),
          );
          return { token, expiresAt };
        }),
        verify: (token) => Effect.map(verifyWithExpiry(token), ({ claims }) => claims),
        verifyWithExpiry,
      });
    }),
  );
}

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

const hex = (bytes: Uint8Array) =>
  Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

/** A new opaque refresh token: `lrt_` plus 32 random bytes, base64url-encoded. */
export const newRefreshToken = Effect.sync(
  () => `lrt_${base64url(crypto.getRandomValues(new Uint8Array(32)))}`,
);

/** The SHA-256 of a string, as lowercase hex. */
export const sha256Hex = (value: string) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).pipe(
    Effect.map((digest) => hex(new Uint8Array(digest))),
  );

/** Refresh tokens are stored only as their SHA-256 hash. */
export const hashRefreshToken = sha256Hex;
