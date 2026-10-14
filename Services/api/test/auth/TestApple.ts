import { Clock, Context, Effect, Layer } from "effect";
import { createLocalJWKSet, exportJWK, generateKeyPair, type JWTPayload, SignJWT } from "jose";
import { AppleKeys, appleAudiences, appleIssuer, AppleSignIn } from "../../src/auth/Apple.ts";
import { ProviderSignIn } from "../../src/auth/ProviderSignIn.ts";
import { sha256Hex } from "../../src/auth/Tokens.ts";
import { TestAuth } from "./TestAuth.ts";

// A stand-in for Apple: a key pair generated for the tests, and identity tokens signed with it.

const { privateKey, publicKey } = await generateKeyPair("RS256");
const kid = "test-apple-key";
const keySet = createLocalJWKSet({
  keys: [{ ...(await exportJWK(publicKey)), kid, alg: "RS256" }],
});
const emptyKeySet = createLocalJWKSet({ keys: [] });

/** How the test Apple key endpoint behaves, and how often it was asked for fresh keys. */
export class TestAppleKeysControl extends Context.Service<
  TestAppleKeysControl,
  { mode: "normal" | "staleCache" | "down"; freshFetches: number }
>()("test/TestAppleKeysControl") {}

/** `AppleKeys` serving the test key, plus `TestAppleKeysControl` to simulate rotation or outages. */
export const TestAppleKeys = Layer.unwrap(
  Effect.sync(() => {
    const control: TestAppleKeysControl["Service"] = { mode: "normal", freshFetches: 0 };
    return Layer.mergeAll(
      Layer.succeed(TestAppleKeysControl, control),
      Layer.succeed(
        AppleKeys,
        AppleKeys.of({
          keys: ({ fresh }) =>
            Effect.suspend(() => {
              if (fresh) control.freshFetches += 1;
              if (control.mode === "down") return Effect.die("Apple is down");
              return Effect.succeed(control.mode === "staleCache" && !fresh ? emptyKeySet : keySet);
            }),
        }),
      ),
    );
  }),
);

/** Apple sign-in over the test keys and a test database, with `TestAuth`'s services. */
export const TestAppleSignIn = Layer.mergeAll(AppleSignIn.layer, ProviderSignIn.layer).pipe(
  Layer.provideMerge(TestAppleKeys),
  Layer.provideMerge(TestAuth),
);

/** An identity token as Apple would issue it, valid for 10 minutes from the clock's now. */
export const appleIdentityToken = (
  claims: JWTPayload & { readonly nonce: string },
  options: {
    readonly audience?: string;
    readonly issuer?: string;
    readonly key?: Parameters<SignJWT["sign"]>[0];
  } = {},
) =>
  Effect.gen(function* () {
    const now = Math.floor((yield* Clock.currentTimeMillis) / 1000);
    const nonce = yield* sha256Hex(claims.nonce);
    return yield* Effect.promise(() =>
      new SignJWT({
        email: "x7y2@privaterelay.appleid.com",
        email_verified: "true",
        ...claims,
        nonce,
      })
        .setProtectedHeader({ alg: "RS256", kid })
        .setIssuer(options.issuer ?? appleIssuer)
        .setAudience(options.audience ?? appleAudiences[0] ?? "")
        .setIssuedAt(now)
        .setExpirationTime(now + 600)
        .sign(options.key ?? privateKey),
    );
  });
