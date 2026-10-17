import { Clock, Context, Effect, Layer, Schema } from "effect";
import { IdentityTokenUses } from "../core/IdentityTokenUses.ts";
import type { InvalidIdentityToken, SignInUnavailable } from "./AuthApi.ts";
import type { VerifiedIdentity } from "./ProviderSignIn.ts";
import {
  checkNonce,
  fetchedProviderKeys,
  type ProviderKeys,
  useOnce,
  verifyProviderToken,
} from "./ProviderTokens.ts";

/** Who issues Sign in with Apple identity tokens. */
export const appleIssuer = "https://appleid.apple.com";

/** The Services ID the Mac's web sign-in uses (`AppleWebSignIn.ts`), under `tech.lil.health`. */
export const appleWebServicesId = "tech.lil.health.web";

/**
 * What Apple puts in the token's audience: the iPhone app's App ID for its native sheet, and the
 * Services ID for the Mac's web sign-in (`AppleWebSignIn.ts`). The Services ID is grouped under
 * the App ID, so a person gets the same Apple user ID in both (851-2538).
 */
export const appleAudiences = ["tech.lil.health", appleWebServicesId];

/** Apple's token signing keys. */
export class AppleKeys extends Context.Service<AppleKeys, ProviderKeys>()(
  "lil/api/auth/AppleKeys",
) {
  static readonly layer = Layer.sync(AppleKeys, () =>
    fetchedProviderKeys("Apple", "https://appleid.apple.com/auth/keys"),
  );
}

const AppleClaims = Schema.Struct({
  sub: Schema.NonEmptyString,
  nonce: Schema.String,
  exp: Schema.Number,
  email: Schema.optionalKey(Schema.String),
  // Apple sends booleans as either booleans or strings.
  email_verified: Schema.optionalKey(
    Schema.Union([Schema.Boolean, Schema.Literals(["true", "false"])]),
  ),
});

/** Verifies Sign in with Apple identity tokens. */
export class AppleSignIn extends Context.Service<
  AppleSignIn,
  {
    /**
     * Verifies an identity token (see `verifyProviderToken`) and its nonce: the app sends Apple
     * the SHA-256 (hex) of a random `nonce` and us the nonce itself. Each token signs in once.
     */
    readonly verify: (
      identityToken: string,
      nonce: string,
      fullName:
        | { readonly givenName?: string | null; readonly familyName?: string | null }
        | undefined,
    ) => Effect.Effect<VerifiedIdentity, InvalidIdentityToken | SignInUnavailable>;
  }
>()("lil/api/auth/AppleSignIn") {
  static readonly layer = Layer.effect(
    AppleSignIn,
    Effect.gen(function* () {
      const keys = yield* AppleKeys;
      const tokenUses = yield* IdentityTokenUses;
      return AppleSignIn.of({
        verify: Effect.fn("AppleSignIn.verify")(function* (identityToken, nonce, fullName) {
          const now = yield* Clock.currentTimeMillis;
          const claims = yield* verifyProviderToken({
            provider: "Apple",
            token: identityToken,
            keys,
            issuer: appleIssuer,
            audience: appleAudiences,
            maxTokenAge: "10m",
            now,
            claims: AppleClaims,
          });
          yield* checkNonce("Apple", claims.nonce, nonce);
          yield* useOnce(tokenUses, "Apple", identityToken, { expiresAt: claims.exp * 1000, now });
          const name = [fullName?.givenName, fullName?.familyName].filter(Boolean).join(" ");
          return {
            provider: "apple",
            subject: claims.sub,
            email: claims.email ?? null,
            emailVerified: claims.email_verified === true || claims.email_verified === "true",
            displayName: name === "" ? null : name,
          } satisfies VerifiedIdentity;
        }),
      });
    }),
  );
}
