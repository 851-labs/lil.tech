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
 * Our Google OAuth clients (851-2538), in the Google Cloud project `lil-tech-851` (org 851.sh).
 * Without any, Google sign-in answers 503.
 *
 * - `apps`: the apps' client IDs, which Google puts in the token's `azp` (or `aud`). One iOS-type
 *   client serves the iPhone and the Mac: they share the bundle ID `tech.lil.health`.
 * - `web`: the Web application client the agents' authorization page signs in with (851-2850,
 *   `GoogleWeb.ts`), whose ID is in `aud` and `azp`. Its secret is the deploy's
 *   `LIL_GOOGLE_WEB_CLIENT_SECRET`.
 * - `server`: a server client ID, which Google would put in `aud` if the apps asked for one. They
 *   don't (they sign in without Google's SDK, `GoogleOAuth.swift`), so it's empty.
 */
export const googleClientIds = {
  apps: [
    "43230766631-5mdd1j3o2dlugafcl2jj2ci39i4a8ski.apps.googleusercontent.com",
  ] as ReadonlyArray<string>,
  web: [
    "43230766631-d4cte9lfc5qitim1d69cqdf1u9c5v2e0.apps.googleusercontent.com",
  ] as ReadonlyArray<string>,
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

/** Verifies Google ID tokens from the apps' sign-in, and from the authorization page's. */
export class GoogleSignIn extends Context.Service<
  GoogleSignIn,
  {
    /**
     * Verifies an ID token (see `verifyProviderToken`): one of `requester`'s clients as audience
     * and authorized party (the apps', by default, or the authorization page's `web` client), the
     * nonce (as with Apple, the app gives Google the SHA-256 of `nonce`), and a verified email.
     * Each token signs in once. A token for one is refused by the other, so the apps' sign-in,
     * which creates accounts, doesn't take the page's.
     */
    readonly verify: (
      idToken: string,
      nonce: string,
      requester?: "apps" | "web",
    ) => Effect.Effect<VerifiedIdentity, InvalidIdentityToken | SignInUnavailable>;
  }
>()("lil/api/auth/GoogleSignIn") {
  static readonly layer = Layer.effect(
    GoogleSignIn,
    Effect.gen(function* () {
      const keys = yield* GoogleKeys;
      const clients = yield* GoogleClients;
      const tokenUses = yield* IdentityTokenUses;
      const invalid = (message: string) => new InvalidIdentityToken({ message });

      return GoogleSignIn.of({
        verify: Effect.fn("GoogleSignIn.verify")(function* (idToken, nonce, requester = "apps") {
          // The clients that asked Google for the token, and those it may be for: the apps' tokens
          // may be for our server client, which the page's never are.
          const requesters = clients[requester];
          const audience = requester === "apps" ? [...requesters, ...clients.server] : requesters;
          if (requesters.length === 0) {
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
          // A token for our server client must have been requested by one of the apps.
          if (claims.azp !== undefined && !requesters.includes(claims.azp)) {
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
