import { Context, Schema } from "effect";
import { HttpApiEndpoint, HttpApiGroup, HttpApiMiddleware, HttpApiSecurity } from "effect/http-api";
import { IdentityProvider } from "../core/Identities.ts";
import { DeviceId, SessionId, UserId } from "../core/Ids.ts";

// The auth part of the API definition. Like `Api.ts`, it holds no server code.

/** Who an access token was issued to. */
export class AccessTokenClaims extends Schema.Class<AccessTokenClaims>(
  "lil/api/auth/AccessTokenClaims",
)({
  userId: UserId,
  deviceId: DeviceId,
  sessionId: SessionId,
}) {}

/** The claims of the request's access token, provided by `Authorization`. */
export class CurrentSession extends Context.Service<CurrentSession, AccessTokenClaims>()(
  "lil/api/auth/CurrentSession",
) {}

export class Unauthorized extends Schema.TaggedError<Unauthorized>()(
  "Unauthorized",
  { message: Schema.String },
  { httpApiStatus: 401 },
) {}

/** Requires a valid access token as a bearer token. */
export class Authorization extends HttpApiMiddleware.Service<
  Authorization,
  { provides: CurrentSession }
>()("lil/api/auth/Authorization", {
  security: { bearer: HttpApiSecurity.bearer },
  error: Unauthorized,
}) {}

/** What a sign-in or refresh returns to the app. */
export class TokenPair extends Schema.Class<TokenPair>("lil/api/auth/TokenPair")(
  {
    accessToken: Schema.String,
    /** Unix milliseconds. */
    accessTokenExpiresAt: Schema.Int,
    refreshToken: Schema.String,
    /** Unix milliseconds. */
    refreshTokenExpiresAt: Schema.Int,
  },
  { description: "An access token for API requests and a refresh token to get the next pair" },
) {}

export class RefreshRequest extends Schema.Class<RefreshRequest>("lil/api/auth/RefreshRequest")({
  refreshToken: Schema.String,
}) {}

/** The refresh token is unknown, expired, already used, or signed out. Sign in again. */
export class InvalidRefreshToken extends Schema.TaggedError<InvalidRefreshToken>()(
  "InvalidRefreshToken",
  { message: Schema.String },
  { httpApiStatus: 401 },
) {}

export class AuthApi extends HttpApiGroup.make("auth")
  .add(
    HttpApiEndpoint.post("refresh", "/v1/auth/refresh", {
      payload: RefreshRequest,
      success: TokenPair,
      error: InvalidRefreshToken,
    }),
  )
  .add(
    // Ends the device's session: its refresh token stops working. Access tokens already issued
    // stay valid until they expire, at most 15 minutes later.
    HttpApiEndpoint.post("signOut", "/v1/auth/sign-out").middleware(Authorization),
  ) {}

export class MeIdentity extends Schema.Class<MeIdentity>("lil/api/auth/MeIdentity")({
  provider: IdentityProvider,
  email: Schema.NullOr(Schema.String),
}) {}

/** The signed-in user. */
export class Me extends Schema.Class<Me>("lil/api/auth/Me")({
  id: UserId,
  displayName: Schema.NullOr(Schema.String),
  /** The accounts the user signs in with. */
  identities: Schema.Array(MeIdentity),
}) {}

export class MeApi extends HttpApiGroup.make("me", { topLevel: true })
  .add(HttpApiEndpoint.get("me", "/v1/me", { success: Me }))
  .middleware(Authorization) {}
