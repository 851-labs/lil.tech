import { Clock, Context, Effect, Layer, Option } from "effect";
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
    ) => Effect.Effect<TokenPair, SqlError.SqlError>;
    /**
     * Exchanges a refresh token for a new pair. The old token stops working. Presenting a token
     * that was already used revokes its whole family, because only a stolen copy would be reused.
     */
    readonly refresh: (
      refreshToken: string,
    ) => Effect.Effect<TokenPair, InvalidRefreshToken | SqlError.SqlError>;
    /** Signs the device out: deletes every token in the session's family. */
    readonly signOut: (sessionId: SessionId) => Effect.Effect<void, SqlError.SqlError>;
  }
>()("lil/api/auth/Auth") {
  static readonly layer = Layer.effect(
    Auth,
    Effect.gen(function* () {
      const sessions = yield* Sessions;
      const devices = yield* Devices;
      const accessTokens = yield* AccessTokens;

      /** Stores a new refresh token in the family (a new one if `familyId` is omitted). */
      const issue = Effect.fnUntraced(function* (
        userId: UserId,
        deviceId: DeviceId,
        familyId?: SessionId,
      ) {
        const now = yield* Clock.currentTimeMillis;
        const refreshToken = yield* newRefreshToken;
        const id = yield* newSessionId;
        const session = new Session({
          id,
          userId,
          deviceId,
          // A family's ID is the ID of its first session.
          familyId: familyId ?? id,
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

      const reused = (familyId: SessionId, now: number) =>
        sessions
          .revokeFamily(familyId, now)
          .pipe(
            Effect.andThen(
              Effect.fail(new InvalidRefreshToken({ message: "Refresh token was already used" })),
            ),
          );

      return Auth.of({
        issueSession: Effect.fn("Auth.issueSession")(function* (userId, deviceId) {
          return yield* issue(userId, deviceId);
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
          if (session.revokedAt !== null) return yield* reused(session.familyId, now);
          if (session.expiresAt <= now) {
            return yield* new InvalidRefreshToken({ message: "Refresh token expired" });
          }

          // The new token is stored before the old one is revoked, and D1 has no transactions over
          // HTTP, so the order is what keeps this safe:
          // - If anything fails before the revoke, the old token still works and the app retries.
          // - Only one concurrent refresh of the same token can revoke it. The others, and a
          //   refresh racing a sign-out, see it already revoked and revoke the family, which by
          //   then includes every token they stored.
          const [, pair] = yield* Effect.all(
            [
              devices.touch(session.deviceId),
              issue(session.userId, session.deviceId, session.familyId),
            ],
            { concurrency: "unbounded" },
          );
          if (!(yield* sessions.revokeIfActive(session.id, now))) {
            return yield* reused(session.familyId, now);
          }
          // Housekeeping only: failing here mustn't lose the new pair, whose parent is now revoked.
          yield* sessions.deleteExpired(session.familyId, now).pipe(Effect.ignore({ log: true }));
          return pair;
        }),
        signOut: Effect.fn("Auth.signOut")(function* (sessionId) {
          yield* sessions.deleteFamilyOf(sessionId);
        }),
      });
    }),
  );
}
