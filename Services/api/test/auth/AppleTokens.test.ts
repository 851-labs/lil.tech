import { assert, describe, it } from "@effect/vitest";
import { Effect, Layer, Option, Redacted } from "effect";
import { TestClock } from "effect/testing";
import {
  AppleTokens,
  maxRevocationAttempts,
  revokeAppleTokens,
} from "../../src/auth/AppleTokens.ts";
import { AppleTokenRevocations } from "../../src/core/AppleTokenRevocations.ts";
import { Identities } from "../../src/core/Identities.ts";
import { Users } from "../../src/core/Users.ts";
import { SqlClient } from "effect/sql";
import { TestCore } from "../core/TestCoreDatabase.ts";
import {
  TestAppleEndpoint,
  TestAppleTokens,
  testAppleCode,
  testAppleRefreshToken,
} from "./TestAppleTokens.ts";

const TestLayer = Layer.mergeAll(TestAppleTokens, TestCore);

const hour = 60 * 60 * 1000;

const forAda = { clientId: "tech.lil.health", subject: "000123.apple.0001" };

/** The test clock at the real time: Apple's client secrets are checked against it. */
const now = Effect.suspend(() => TestClock.setTime(Date.now()));

/**
 * The test clock a second past the real time, so tokens just queued are due: the trigger stamps
 * them with the database's clock, in whole seconds.
 */
const queuedAreDue = Effect.suspend(() => TestClock.setTime(Date.now() + 1000));

describe("AppleTokens", () => {
  it.effect("redeems a code for Apple's refresh token, kept encrypted, and revokes it", () =>
    Effect.gen(function* () {
      yield* now;
      const tokens = yield* AppleTokens;
      const endpoint = yield* TestAppleEndpoint;
      const code = testAppleCode("000123.apple.0001");

      const stored = yield* tokens.exchange(code, {
        clientId: "tech.lil.health",
        subject: "000123.apple.0001",
      });
      assert.isTrue(Option.isSome(stored));
      const encrypted = Option.getOrThrow(stored);
      assert.notInclude(encrypted, testAppleRefreshToken(code));
      assert.deepInclude(endpoint.calls[0], { path: "/auth/token" });
      assert.deepInclude(endpoint.calls[0]?.form, {
        code,
        grant_type: "authorization_code",
        client_id: "tech.lil.health",
      });

      yield* tokens.revoke(encrypted, "tech.lil.health");
      assert.deepInclude(endpoint.calls[1], { path: "/auth/revoke" });
      assert.deepInclude(endpoint.calls[1]?.form, {
        token: testAppleRefreshToken(code),
        token_type_hint: "refresh_token",
        client_id: "tech.lil.health",
      });
    }).pipe(Effect.provide(TestLayer)),
  );

  it.effect("sends the web sign-in's redirect URI with its code", () =>
    Effect.gen(function* () {
      yield* now;
      const tokens = yield* AppleTokens;
      const endpoint = yield* TestAppleEndpoint;
      const redirectUri = "https://api.lil.tech/v1/auth/apple/web";
      yield* tokens.exchange(testAppleCode("000123.apple.0001"), { ...forAda, redirectUri });
      assert.strictEqual(endpoint.calls[0]?.form["redirect_uri"], redirectUri);
    }).pipe(Effect.provide(TestLayer)),
  );

  it.effect("keeps nothing when Apple refuses the code or it's someone else's", () =>
    Effect.gen(function* () {
      yield* now;
      const tokens = yield* AppleTokens;
      const endpoint = yield* TestAppleEndpoint;
      const someoneElses = testAppleCode("000999.apple.0009");
      assert.isTrue(Option.isNone(yield* tokens.exchange(someoneElses, forAda)));
      endpoint.answerWith(() => ({ status: 400, body: '{"error":"invalid_grant"}' }));
      const code = testAppleCode("000123.apple.0001");
      assert.isTrue(Option.isNone(yield* tokens.exchange(code, forAda)));
    }).pipe(Effect.provide(TestLayer)),
  );

  it.effect("doesn't call Apple without a signing key", () =>
    Effect.gen(function* () {
      const endpoint = yield* TestAppleEndpoint;
      const tokens = AppleTokens.make({
        signingKey: Option.none(),
        tokenSecret: Redacted.make("test-token-key"),
        post: endpoint.post,
      });
      const code = testAppleCode("000123.apple.0001");
      assert.isTrue(Option.isNone(yield* tokens.exchange(code, forAda)));
      assert.lengthOf(endpoint.calls, 0);
    }).pipe(Effect.provide(TestAppleEndpoint.layer)),
  );
});

describe("revokeAppleTokens", () => {
  /** A deleted user whose Apple identity had a stored token, so it's queued for revocation. */
  const queued = (subject: string) =>
    Effect.gen(function* () {
      yield* now;
      const tokens = yield* AppleTokens;
      const user = yield* (yield* Users).create({ displayName: null });
      const identities = yield* Identities;
      yield* identities.create({
        userId: user.id,
        provider: "apple",
        subject,
        email: null,
        emailVerified: false,
      });
      const encrypted = yield* tokens.exchange(testAppleCode(subject), {
        clientId: "tech.lil.health",
        subject,
      });
      yield* identities.saveAppleToken(subject, Option.getOrThrow(encrypted), "tech.lil.health");
      const ids = (yield* identities.listForUser(user.id)).map((identity) => identity.id);
      yield* (yield* Users).delete(user.id);
      return ids;
    });

  it.effect("revokes due tokens and forgets them", () =>
    Effect.gen(function* () {
      const ids = yield* queued("000123.apple.0001");
      const revocations = yield* AppleTokenRevocations;
      // Queued as the user's deletion cascaded to the identity.
      assert.lengthOf(yield* revocations.find(ids), 1);
      assert.lengthOf(yield* revocations.listDue(Date.now() + 1000, 10), 1);
      yield* queuedAreDue;
      assert.strictEqual(yield* revokeAppleTokens(), 1);
      assert.deepStrictEqual(yield* revocations.find(ids), []);
      const endpoint = yield* TestAppleEndpoint;
      assert.lengthOf(
        endpoint.calls.filter((call) => call.path === "/auth/revoke"),
        1,
      );
    }).pipe(Effect.provide(TestLayer)),
  );

  it.effect("tries failures again later, then gives up", () =>
    Effect.gen(function* () {
      yield* queued("000123.apple.0001");
      const revocations = yield* AppleTokenRevocations;
      const endpoint = yield* TestAppleEndpoint;
      endpoint.answerWith(() => ({ status: 503, body: "" }));

      yield* queuedAreDue;
      const failedAt = Date.now() + 1000;
      assert.strictEqual(yield* revokeAppleTokens(), 0);
      const [waiting] = yield* revocations.listDue(failedAt + hour + 1000, 10);
      assert.strictEqual(waiting?.attempts, 1);
      // Not due again until an hour later.
      assert.lengthOf(yield* revocations.listDue(failedAt + hour - 2000, 10), 0);

      for (let attempt = 2; attempt <= maxRevocationAttempts; attempt++) {
        yield* TestClock.adjust(24 * hour);
        yield* revokeAppleTokens();
      }
      assert.lengthOf(yield* revocations.listDue(failedAt + 1000 * 24 * hour, 10), 0);
    }).pipe(Effect.provide(TestLayer)),
  );

  it.effect("forgets tokens Apple says are no good", () =>
    Effect.gen(function* () {
      yield* queued("000123.apple.0001");
      const endpoint = yield* TestAppleEndpoint;
      endpoint.answerWith(() => ({ status: 400, body: '{"error":"invalid_grant"}' }));
      yield* queuedAreDue;
      assert.strictEqual(yield* revokeAppleTokens(), 1);
      assert.lengthOf(yield* (yield* AppleTokenRevocations).listDue(Date.now() + 1000, 10), 0);
    }).pipe(Effect.provide(TestLayer)),
  );

  it.effect("queues a newer token over one already queued for the same identity", () =>
    Effect.gen(function* () {
      const ids = yield* queued("000123.apple.0001");
      const revocations = yield* AppleTokenRevocations;
      const [id] = ids;
      if (id === undefined) return assert.fail("Nothing was queued");
      yield* revocations.postpone(id, 3, Date.now() + hour);
      // The same identity again, deleted again with a newer token.
      const sql = yield* SqlClient.SqlClient;
      const user = yield* (yield* Users).create({ displayName: null });
      yield* sql`INSERT INTO identities
        (id, user_id, provider, subject, email, email_verified, created_at,
          apple_refresh_token, apple_client_id)
        VALUES (${id}, ${user.id}, 'apple', 'again', NULL, 0, 0, 'newer', 'tech.lil.health.web')`;
      yield* (yield* Users).delete(user.id);
      assert.deepInclude((yield* revocations.find(ids))[0], {
        refreshToken: "newer",
        clientId: "tech.lil.health.web",
        attempts: 0,
      });
    }).pipe(Effect.provide(TestLayer)),
  );
});
