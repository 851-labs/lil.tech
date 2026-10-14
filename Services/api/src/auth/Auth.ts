import { Clock, Context, Effect, Layer, Option, Schema } from "effect";
import type { SqlError } from "effect/sql";
import { Devices } from "../core/Devices.ts";
import { type DeviceId, newSessionId, type SessionId, type UserId } from "../core/Ids.ts";
import { Session, Sessions } from "../core/Sessions.ts";
import { AccessTokenClaims, InvalidRefreshToken, TokenPair } from "./AuthApi.ts";
import {
  AccessTokens,
  hashRefreshToken,
  newRefreshToken,
  refreshTokenLifetimeMs,
} from "./Tokens.ts";

export class Auth extends Context.Service<
  Auth,
  {
    /** Starts a new session (a new refresh-token family) for a device that just signed in. */
    readonly issueSession: (
      userId: UserId,
      deviceId: DeviceId,
    ) => Effect.Effect<TokenPair, SqlError.SqlError | Schema.SchemaError>;
    /**
     * Exchanges a refresh token for a new pair. The old token stops working. Presenting a token
     * that was already used revokes its whole family, because only a stolen copy would be reused.
     */
    readonly refresh: (
      refreshToken: string,
    ) => Effect.Effect<TokenPair, InvalidRefreshToken | SqlError.SqlError | Schema.SchemaError>;
    /** Signs the device out: revokes every token in the session's family. */
    readonly signOut: (sessionId: SessionId) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/auth/Auth") {
  static readonly layer = Layer.effect(
    Auth,
    Effect.gen(function* () {
      const sessions = yield* Sessions;
      const devices = yield* Devices;
      const accessTokens = yield* AccessTokens;

      const issue = Effect.fnUntraced(function* (
        userId: UserId,
        deviceId: DeviceId,
        familyId: string,
      ) {
        const now = yield* Clock.currentTimeMillis;
        const refreshToken = yield* newRefreshToken;
        const session = yield* Schema.decodeUnknownEffect(Session)({
          id: yield* newSessionId,
          userId,
          deviceId,
          familyId,
          createdAt: now,
          expiresAt: now + refreshTokenLifetimeMs,
          revokedAt: null,
        });
        yield* sessions.create(session, yield* hashRefreshToken(refreshToken));
        const access = yield* accessTokens.sign(
          new AccessTokenClaims({ userId, deviceId, sessionId: session.id }),
        );
        return new TokenPair({
          accessToken: access.token,
          accessTokenExpiresAt: access.expiresAt,
          refreshToken,
          refreshTokenExpiresAt: session.expiresAt,
        });
      });

      return Auth.of({
        issueSession: Effect.fn("Auth.issueSession")(function* (userId, deviceId) {
          // A session's family ID is its first session's ID.
          const familyId = yield* newSessionId;
          return yield* issue(userId, deviceId, familyId);
        }),
        refresh: Effect.fn("Auth.refresh")(function* (refreshToken) {
          const now = yield* Clock.currentTimeMillis;
          const found = yield* sessions.findByRefreshTokenHash(
            yield* hashRefreshToken(refreshToken),
          );
          if (Option.isNone(found)) {
            return yield* new InvalidRefreshToken({ message: "Unknown refresh token" });
          }
          const session = found.value;
          if (session.revokedAt !== null) {
            yield* sessions.revokeFamily(session.familyId, now);
            return yield* new InvalidRefreshToken({ message: "Refresh token was already used" });
          }
          if (session.expiresAt <= now) {
            return yield* new InvalidRefreshToken({ message: "Refresh token expired" });
          }
          // Only one concurrent refresh of the same token wins; the loser is treated as reuse.
          if (!(yield* sessions.revokeIfActive(session.id, now))) {
            yield* sessions.revokeFamily(session.familyId, now);
            return yield* new InvalidRefreshToken({ message: "Refresh token was already used" });
          }
          yield* devices.touch(session.deviceId);
          return yield* issue(session.userId, session.deviceId, session.familyId);
        }),
        signOut: Effect.fn("Auth.signOut")(function* (sessionId) {
          const now = yield* Clock.currentTimeMillis;
          yield* sessions.revokeFamilyOf(sessionId, now);
        }),
      });
    }),
  );
}
