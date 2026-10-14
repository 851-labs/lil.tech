import { assert, layer } from "@effect/vitest";
import { Clock, Effect, Layer, Option, Redacted } from "effect";
import { TestClock } from "effect/testing";
import { SqlClient } from "effect/sql";
import { Auth } from "../../src/auth/Auth.ts";
import { AccessTokenClaims } from "../../src/auth/AuthApi.ts";
import { AccessTokens, SessionKey } from "../../src/auth/Tokens.ts";
import { Devices } from "../../src/core/Devices.ts";
import { Sessions } from "../../src/core/Sessions.ts";
import { Users } from "../../src/core/Users.ts";
import { TestAuth } from "./TestAuth.ts";

const signIn = Effect.gen(function* () {
  const user = yield* (yield* Users).create({ displayName: "Ada" });
  const device = yield* (yield* Devices).create({
    userId: user.id,
    app: "health-ios",
    platform: "ios",
    name: null,
  });
  const tokens = yield* (yield* Auth).issueSession(user.id, device.id);
  return { user, device, tokens };
});

const refreshFails = (refreshToken: string) =>
  Effect.gen(function* () {
    const error = yield* Effect.flip((yield* Auth).refresh(refreshToken));
    assert.strictEqual(error._tag, "InvalidRefreshToken");
  });

layer(TestAuth)("Auth", (it) => {
  it.effect("issues an access token for the device and an opaque refresh token", () =>
    Effect.gen(function* () {
      const { user, device, tokens } = yield* signIn;
      const claims = yield* (yield* AccessTokens).verify(tokens.accessToken);
      assert.strictEqual(claims.userId, user.id);
      assert.strictEqual(claims.deviceId, device.id);
      const now = yield* Clock.currentTimeMillis;
      assert.strictEqual(tokens.accessTokenExpiresAt, now + 15 * 60 * 1000);
      assert.strictEqual(tokens.refreshTokenExpiresAt, now + 90 * 24 * 60 * 60 * 1000);
      assert.match(tokens.refreshToken, /^lrt_[\w-]{43}$/);

      // Only the hash is stored.
      const sql = yield* SqlClient.SqlClient;
      const stored = yield* sql`SELECT refresh_token_hash AS hash FROM sessions
        WHERE id = ${claims.sessionId}`;
      assert.match(String(stored[0]?.["hash"]), /^[0-9a-f]{64}$/);
      assert.notInclude(String(stored[0]?.["hash"]), tokens.refreshToken);
    }),
  );

  it.effect("access tokens expire after 15 minutes", () =>
    Effect.gen(function* () {
      const { tokens } = yield* signIn;
      const accessTokens = yield* AccessTokens;
      yield* TestClock.adjust("14 minutes");
      yield* accessTokens.verify(tokens.accessToken);
      yield* TestClock.adjust("1 minute");
      const error = yield* Effect.flip(accessTokens.verify(tokens.accessToken));
      assert.strictEqual(error._tag, "InvalidAccessToken");
    }),
  );

  it.effect("rejects tampered access tokens and tokens signed with another key", () =>
    Effect.gen(function* () {
      const { tokens } = yield* signIn;
      const accessTokens = yield* AccessTokens;
      const claims = yield* accessTokens.verify(tokens.accessToken);

      const [header, payload, signature] = tokens.accessToken.split(".");
      const forged = JSON.parse(atob(payload ?? "")) as Record<string, unknown>;
      forged["sub"] = "usr_00000000000000000000000000";
      const tampered = [header, btoa(JSON.stringify(forged)).replace(/=+$/, ""), signature].join(
        ".",
      );
      assert.strictEqual(
        (yield* Effect.flip(accessTokens.verify(tampered)))._tag,
        "InvalidAccessToken",
      );
      assert.strictEqual(
        (yield* Effect.flip(accessTokens.verify("not-a-jwt")))._tag,
        "InvalidAccessToken",
      );

      const otherKey = yield* Effect.gen(function* () {
        return yield* (yield* AccessTokens).sign(new AccessTokenClaims(claims));
      }).pipe(
        Effect.provide(
          Layer.fresh(AccessTokens.layer).pipe(
            Layer.provide(Layer.succeed(SessionKey, Redacted.make("another-key"))),
          ),
        ),
      );
      assert.strictEqual(
        (yield* Effect.flip(accessTokens.verify(otherKey.token)))._tag,
        "InvalidAccessToken",
      );
    }),
  );

  it.effect("refreshing rotates the refresh token, and reusing an old one ends the session", () =>
    Effect.gen(function* () {
      const auth = yield* Auth;
      const accessTokens = yield* AccessTokens;
      const { device, tokens: first } = yield* signIn;
      const firstClaims = yield* accessTokens.verify(first.accessToken);

      yield* TestClock.adjust("1 hour");
      const second = yield* auth.refresh(first.refreshToken);
      assert.notStrictEqual(second.refreshToken, first.refreshToken);
      const secondClaims = yield* accessTokens.verify(second.accessToken);
      assert.strictEqual(secondClaims.deviceId, device.id);
      assert.notStrictEqual(secondClaims.sessionId, firstClaims.sessionId);
      const touched = yield* (yield* Devices).findById(device.id);
      assert.deepStrictEqual(
        Option.map(touched, (d) => d.lastSeenAt),
        Option.some(yield* Clock.currentTimeMillis),
      );

      // Only a stolen copy would present the first token again, so the whole family ends,
      // including the token the legitimate device holds now.
      yield* refreshFails(first.refreshToken);
      yield* refreshFails(second.refreshToken);
    }),
  );

  it.effect("refresh tokens expire 90 days after their last use", () =>
    Effect.gen(function* () {
      const auth = yield* Auth;
      const { tokens } = yield* signIn;
      yield* TestClock.adjust("89 days");
      const next = yield* auth.refresh(tokens.refreshToken);
      yield* TestClock.adjust("89 days");
      const last = yield* auth.refresh(next.refreshToken);
      yield* TestClock.adjust("90 days");
      yield* refreshFails(last.refreshToken);
    }),
  );

  it.effect("rejects unknown refresh tokens", () => refreshFails("lrt_unknown"));

  it.effect("signing out ends the session's whole family", () =>
    Effect.gen(function* () {
      const auth = yield* Auth;
      const { tokens } = yield* signIn;
      const next = yield* auth.refresh(tokens.refreshToken);
      const claims = yield* (yield* AccessTokens).verify(next.accessToken);
      yield* auth.signOut(claims.sessionId);
      yield* refreshFails(next.refreshToken);
    }),
  );

  it.effect("signing out one device leaves the user's other devices signed in", () =>
    Effect.gen(function* () {
      const auth = yield* Auth;
      const { user, tokens: phone } = yield* signIn;
      const mac = yield* (yield* Devices).create({
        userId: user.id,
        app: "health-mac",
        platform: "macos",
        name: null,
      });
      const macTokens = yield* auth.issueSession(user.id, mac.id);
      const claims = yield* (yield* AccessTokens).verify(phone.accessToken);
      yield* auth.signOut(claims.sessionId);
      yield* refreshFails(phone.refreshToken);
      yield* auth.refresh(macTokens.refreshToken);
    }),
  );

  it.effect("only one of two concurrent refreshes of the same token can rotate it", () =>
    Effect.gen(function* () {
      const sessions = yield* Sessions;
      const { tokens } = yield* signIn;
      const claims = yield* (yield* AccessTokens).verify(tokens.accessToken);
      const now = yield* Clock.currentTimeMillis;
      assert.isTrue(yield* sessions.revokeIfActive(claims.sessionId, now));
      assert.isFalse(yield* sessions.revokeIfActive(claims.sessionId, now));
    }),
  );

  it.effect("deleting a device deletes its sessions", () =>
    Effect.gen(function* () {
      const { device, tokens } = yield* signIn;
      yield* (yield* Devices).delete(device.id);
      yield* refreshFails(tokens.refreshToken);
    }),
  );
});
