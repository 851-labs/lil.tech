import { Clock, Effect, Layer } from "effect";
import { createLocalJWKSet, exportJWK, generateKeyPair, type JWTPayload, SignJWT } from "jose";
import { AppleKeys, appleAudiences, appleIssuer } from "../../src/auth/Apple.ts";

// A stand-in for Apple: a key pair generated for the tests, and identity tokens signed with it.

const { privateKey, publicKey } = await generateKeyPair("RS256");
const kid = "test-apple-key";

export const TestAppleKeys = Layer.effect(
  AppleKeys,
  Effect.promise(async () =>
    createLocalJWKSet({ keys: [{ ...(await exportJWK(publicKey)), kid, alg: "RS256" }] }),
  ),
);

export const sha256Hex = async (value: string) =>
  Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");

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
    return yield* Effect.promise(async () =>
      new SignJWT({
        email: "x7y2@privaterelay.appleid.com",
        email_verified: "true",
        ...claims,
        nonce: await sha256Hex(claims.nonce),
      })
        .setProtectedHeader({ alg: "RS256", kid })
        .setIssuer(options.issuer ?? appleIssuer)
        .setAudience(options.audience ?? appleAudiences[0] ?? "")
        .setIssuedAt(now)
        .setExpirationTime(now + 600)
        .sign(options.key ?? privateKey),
    );
  });
