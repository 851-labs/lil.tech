import { Clock, Context, Effect, Layer, Option, Redacted } from "effect";
import { type JWTPayload, SignJWT } from "jose";
import { GoogleClients, GoogleKeys, GoogleSignIn } from "../../src/auth/Google.ts";
import { type GooglePost, GoogleWebClient } from "../../src/auth/GoogleWeb.ts";
import { ProviderSignIn } from "../../src/auth/ProviderSignIn.ts";
import { sha256Hex } from "../../src/auth/Tokens.ts";
import { TestAuth } from "./TestAuth.ts";
import { makeTestProviderKeys } from "./TestProviderKeys.ts";

// A stand-in for Google: a key pair generated for the tests, and ID tokens signed with it.

const google = await makeTestProviderKeys("test-google-key");

/** Simulates Google's key endpoint having a stale cache or being down. */
export const testGoogleKeysControl = google.control;

/** Made-up OAuth client IDs for the test apps, the authorization page and a server. */
export const testGoogleClients = {
  apps: ["000000000000-ios.apps.googleusercontent.com"],
  web: ["000000000000-web.apps.googleusercontent.com"],
  server: ["000000000000-server.apps.googleusercontent.com"],
};

export const TestGoogleKeys = Layer.succeed(GoogleKeys, google.keys);

export const TestGoogleClients = Layer.succeed(GoogleClients, testGoogleClients);

/** Google sign-in over the test keys and a test database, with `TestAuth`'s services. */
export const TestGoogleSignIn = Layer.mergeAll(GoogleSignIn.layer, ProviderSignIn.layer).pipe(
  Layer.provideMerge(Layer.mergeAll(TestGoogleKeys, TestGoogleClients)),
  Layer.provideMerge(TestAuth),
);

/**
 * An ID token as Google would issue it to the test iOS app for `nonce`, valid for an hour from
 * the clock's now.
 */
export const googleIdToken = (
  claims: JWTPayload & { readonly nonce: string },
  options: { readonly audience?: string; readonly issuer?: string } = {},
) =>
  Effect.gen(function* () {
    const now = Math.floor((yield* Clock.currentTimeMillis) / 1000);
    const nonce = yield* sha256Hex(claims.nonce);
    return yield* Effect.promise(() =>
      new SignJWT({
        email: "ada@example.com",
        email_verified: true,
        name: "Ada",
        // Real tokens differ per sign-in; without this, two at the same instant would be identical.
        jti: crypto.randomUUID(),
        ...claims,
        nonce,
      })
        .setProtectedHeader({ alg: "RS256", kid: google.kid })
        .setIssuer(options.issuer ?? "https://accounts.google.com")
        .setAudience(options.audience ?? testGoogleClients.apps[0] ?? "")
        .setIssuedAt(now)
        .setExpirationTime(now + 3600)
        .sign(google.privateKey),
    );
  });

export interface GoogleTokenCall {
  readonly form: Readonly<Record<string, string>>;
}

/** The test web client's secret. */
export const testGoogleWebClientSecret = "test-google-web-secret";

/**
 * A stand-in for Google's token endpoint, for the authorization page's web client: the requests it
 * got, and how it answers (by default, refusing every code until a test says what to answer).
 */
export class TestGoogleTokenEndpoint extends Context.Service<
  TestGoogleTokenEndpoint,
  {
    readonly calls: Array<GoogleTokenCall>;
    readonly post: GooglePost;
    /** Answers with `answer` from now on. */
    readonly answerWith: (
      answer: (call: GoogleTokenCall) => { readonly status: number; readonly body: string },
    ) => void;
  }
>()("test/TestGoogleTokenEndpoint") {
  static readonly layer = Layer.sync(TestGoogleTokenEndpoint, () => {
    const calls: Array<GoogleTokenCall> = [];
    let answer: (call: GoogleTokenCall) => {
      readonly status: number;
      readonly body: string;
    } = () => ({ status: 400, body: JSON.stringify({ error: "invalid_grant" }) });
    return TestGoogleTokenEndpoint.of({
      calls,
      post: async (form) => {
        calls.push({ form });
        return answer({ form });
      },
      answerWith: (next) => {
        answer = next;
      },
    });
  });
}

/** The authorization page's Google client over the fake token endpoint, with a secret. */
export const TestGoogleWebClient = Layer.unwrap(
  Effect.map(TestGoogleTokenEndpoint, (endpoint) =>
    GoogleWebClient.layer({
      clientSecret: Option.some(Redacted.make(testGoogleWebClientSecret)),
      post: endpoint.post,
    }),
  ),
).pipe(Layer.provideMerge(TestGoogleTokenEndpoint.layer), Layer.provide(TestGoogleClients));
