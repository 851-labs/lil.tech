import { Clock, Context, Effect, Layer, Schema } from "effect";
import { IdentityTokenUses } from "../core/IdentityTokenUses.ts";
import { InvalidIdentityToken, SignInUnavailable } from "./AuthApi.ts";
import type { VerifiedIdentity } from "./ProviderSignIn.ts";
import {
  checkNonce,
  fetchedProviderKeys,
  type ProviderKeys,
  useOnce,
  verifyProviderToken,
} from "./ProviderTokens.ts";

/** Google issues ID tokens under either issuer. */
export const googleIssuers = ["https://accounts.google.com", "accounts.google.com"];

/**
 * Our Google OAuth clients (851-2538). Empty until they're registered; until then Google sign-in
 * answers 503.
 *
 * - `apps`: the iOS and macOS client IDs, which Google puts in the token's `azp` (or `aud`).
 * - `server`: a server client ID, if the apps set one (`GIDConfiguration.serverClientID`), which
 *   Google then puts in `aud`.
 */
export const googleClientIds = {
  apps: [] as ReadonlyArray<string>,
  server: [] as ReadonlyArray<string>,
};

/** Which Google OAuth clients may sign in. */
export class GoogleClients extends Context.Service<GoogleClients, typeof googleClientIds>()(
  "lil/api/auth/GoogleClients",
) {
  static readonly layer = Layer.succeed(GoogleClients, googleClientIds);
}

/** Google's token signing keys. */
export class GoogleKeys extends Context.Service<GoogleKeys, ProviderKeys>()(
  "lil/api/auth/GoogleKeys",
) {
  static readonly layer = Layer.sync(GoogleKeys, () =>
    fetchedProviderKeys("Google", "https://www.googleapis.com/oauth2/v3/certs"),
  );
}

const GoogleClaims = Schema.Struct({
  sub: Schema.NonEmptyString,
  exp: Schema.Number,
  nonce: Schema.String,
  azp: Schema.optionalKey(Schema.String),
  email: Schema.optionalKey(Schema.String),
  email_verified: Schema.optionalKey(Schema.Boolean),
  name: Schema.optionalKey(Schema.String),
});

/** Verifies Google ID tokens from the apps' native sign-in. */
export class GoogleSignIn extends Context.Service<
  GoogleSignIn,
  {
    /**
     * Verifies an ID token (see `verifyProviderToken`): one of our clients as audience and
     * authorized party, the nonce (as with Apple, the app gives Google the SHA-256 of `nonce`),
     * and a verified email. Each token signs in once.
     */
    readonly verify: (
      idToken: string,
      nonce: string,
    ) => Effect.Effect<VerifiedIdentity, InvalidIdentityToken | SignInUnavailable>;
  }
>()("lil/api/auth/GoogleSignIn") {
  static readonly layer = Layer.effect(
    GoogleSignIn,
    Effect.gen(function* () {
      const keys = yield* GoogleKeys;
      const clients = yield* GoogleClients;
      const tokenUses = yield* IdentityTokenUses;
      const audience = [...clients.apps, ...clients.server];
      const invalid = (message: string) => new InvalidIdentityToken({ message });

      return GoogleSignIn.of({
        verify: Effect.fn("GoogleSignIn.verify")(function* (idToken, nonce) {
          if (clients.apps.length === 0) {
            return yield* new SignInUnavailable({ message: "Google sign-in isn't set up yet" });
          }
          const now = yield* Clock.currentTimeMillis;
          const claims = yield* verifyProviderToken({
            provider: "Google",
            token: idToken,
            keys,
            issuer: googleIssuers,
            audience,
            maxTokenAge: "10m",
            now,
            claims: GoogleClaims,
          });
          // A token for our server client must have been requested by one of our apps.
          if (claims.azp !== undefined && !clients.apps.includes(claims.azp)) {
            return yield* invalid("The Google token was issued to another app");
          }
          yield* checkNonce("Google", claims.nonce, nonce);
          // Google accounts can carry unverified addresses; sign-in requires a verified one.
          if (claims.email === undefined || claims.email_verified !== true) {
            return yield* invalid("The Google account's email isn't verified");
          }
          yield* useOnce(tokenUses, "Google", idToken, { expiresAt: claims.exp * 1000, now });
          return {
            provider: "google",
            subject: claims.sub,
            email: claims.email,
            emailVerified: true,
            displayName: claims.name ?? null,
          } satisfies VerifiedIdentity;
        }),
      });
    }),
  );
}
