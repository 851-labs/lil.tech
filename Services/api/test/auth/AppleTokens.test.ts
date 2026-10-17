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
import { TestCore } from "../core/TestCoreDatabase.ts";
import {
  TestAppleEndpoint,
  TestAppleTokens,
  testAppleCode,
  testAppleRefreshToken,
} from "./TestAppleTokens.ts";

const TestLayer = Layer.mergeAll(TestAppleTokens, TestCore);

const hour = 60 * 60 * 1000;

describe("AppleTokens", () => {
  it.effect("redeems a code for Apple's refresh token, kept encrypted, and revokes it", () =>
    Effect.gen(function* () {
      const tokens = yield* AppleTokens;
      const endpoint = yield* TestAppleEndpoint;
      const code = testAppleCode("000123.apple.0001");

      const stored = yield* tokens.exchange(code, "tech.lil.health", "000123.apple.0001");
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

  it.effect("keeps nothing when Apple refuses the code or it's someone else's", () =>
    Effect.gen(function* () {
      const tokens = yield* AppleTokens;
      const endpoint = yield* TestAppleEndpoint;
      const someoneElses = testAppleCode("000999.apple.0009");
      assert.isTrue(
        Option.isNone(yield* tokens.exchange(someoneElses, "tech.lil.health", "000123.apple.0001")),
      );
      endpoint.answerWith(() => ({ status: 400, body: '{"error":"invalid_grant"}' }));
      const code = testAppleCode("000123.apple.0001");
      assert.isTrue(
        Option.isNone(yield* tokens.exchange(code, "tech.lil.health", "000123.apple.0001")),
      );
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
      assert.isTrue(
        Option.isNone(yield* tokens.exchange(code, "tech.lil.health", "000123.apple.0001")),
      );
      assert.lengthOf(endpoint.calls, 0);
    }).pipe(Effect.provide(TestAppleEndpoint.layer)),
  );
});

describe("revokeAppleTokens", () => {
  /** A user whose Apple identity has a stored token, queued for revocation as deletion does. */
  const queued = (subject: string) =>
    Effect.gen(function* () {
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
      const encrypted = yield* tokens.exchange(testAppleCode(subject), "tech.lil.health", subject);
      yield* identities.saveAppleToken(subject, Option.getOrThrow(encrypted), "tech.lil.health");
      const revocations = yield* AppleTokenRevocations;
      const ids = yield* revocations.addForUser(user.id, 0);
      // Again, as a retried deletion would: nothing more is queued.
      assert.deepStrictEqual(yield* revocations.addForUser(user.id, 0), ids);
      return ids;
    });

  it.effect("revokes due tokens and forgets them", () =>
    Effect.gen(function* () {
      const [id] = yield* queued("000123.apple.0001");
      const revocations = yield* AppleTokenRevocations;
      assert.lengthOf(yield* revocations.listDue(0, 10), 1);
      assert.strictEqual(yield* revokeAppleTokens(), 1);
      assert.deepStrictEqual(yield* revocations.find(id === undefined ? [] : [id]), []);
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

      assert.strictEqual(yield* revokeAppleTokens(), 0);
      const [waiting] = yield* revocations.listDue(hour, 10);
      assert.strictEqual(waiting?.attempts, 1);
      // Not due again until an hour later.
      assert.lengthOf(yield* revocations.listDue(hour - 1, 10), 0);

      for (let attempt = 2; attempt <= maxRevocationAttempts; attempt++) {
        yield* TestClock.adjust(24 * hour);
        yield* revokeAppleTokens();
      }
      assert.lengthOf(yield* revocations.listDue(1000 * 24 * hour, 10), 0);
    }).pipe(Effect.provide(TestLayer)),
  );

  it.effect("forgets tokens Apple says are no good", () =>
    Effect.gen(function* () {
      yield* queued("000123.apple.0001");
      const endpoint = yield* TestAppleEndpoint;
      endpoint.answerWith(() => ({ status: 400, body: '{"error":"invalid_grant"}' }));
      assert.strictEqual(yield* revokeAppleTokens(), 1);
      assert.lengthOf(yield* (yield* AppleTokenRevocations).listDue(0, 10), 0);
    }).pipe(Effect.provide(TestLayer)),
  );
});
