import { Context, Effect, Layer, Option, Redacted } from "effect";
import { exportPKCS8, generateKeyPair, jwtVerify, UnsecuredJWT } from "jose";
import { type ApplePost, appleTeamId, AppleTokens } from "../../src/auth/AppleTokens.ts";

// A stand-in for Apple's token endpoints: a Sign in with Apple key generated for the tests, and a
// fake `/auth/token` and `/auth/revoke` that check each request's client secret.

const key = await generateKeyPair("ES256", { extractable: true });

/** The test Sign in with Apple key, a PKCS #8 PEM. */
export const testAppleSignInKey = await exportPKCS8(key.privateKey);

/** An authorization code for the Apple account `subject`, as the fake endpoint redeems it. */
export const testAppleCode = (subject: string) => `${subject}/${crypto.randomUUID()}`;

/** The refresh token the fake endpoint gives for `code`. */
export const testAppleRefreshToken = (code: string) => `refresh-${code}`;

export interface AppleCall {
  readonly path: "/auth/token" | "/auth/revoke";
  readonly form: Readonly<Record<string, string>>;
}

type Answer = (call: AppleCall) => { readonly status: number; readonly body: string };

/** Apple's answers by default: tokens for every code, and every revocation done. */
const answerOk: Answer = ({ path, form }) =>
  path === "/auth/revoke"
    ? { status: 200, body: "" }
    : {
        status: 200,
        body: JSON.stringify({
          access_token: "access",
          refresh_token: testAppleRefreshToken(form["code"] ?? ""),
          id_token: new UnsecuredJWT({ sub: (form["code"] ?? "").split("/")[0] ?? "" }).encode(),
        }),
      };

/** The fake endpoint: the requests it got, and how it answers. */
export class TestAppleEndpoint extends Context.Service<
  TestAppleEndpoint,
  {
    readonly calls: Array<AppleCall>;
    readonly post: ApplePost;
    /** Answers with `answer` from now on. */
    readonly answerWith: (answer: Answer) => void;
  }
>()("test/TestAppleEndpoint") {
  static readonly layer = Layer.sync(TestAppleEndpoint, () => {
    const calls: Array<AppleCall> = [];
    let answer = answerOk;
    return TestAppleEndpoint.of({
      calls,
      post: async (path, form) => {
        const clientId = form["client_id"] ?? "";
        // Throws (failing the request) unless the secret is ours, for this client, and current.
        await jwtVerify(form["client_secret"] ?? "", key.publicKey, {
          issuer: appleTeamId,
          audience: "https://appleid.apple.com",
          subject: clientId,
          maxTokenAge: "5m",
        });
        calls.push({ path, form });
        return answer({ path, form });
      },
      answerWith: (next) => {
        answer = next;
      },
    });
  });
}

/** `AppleTokens` over the fake endpoint, with the test key, and the endpoint. */
export const TestAppleTokens = Layer.effect(
  AppleTokens,
  Effect.gen(function* () {
    const endpoint = yield* TestAppleEndpoint;
    return AppleTokens.make({
      signingKey: Option.some(Redacted.make(testAppleSignInKey)),
      tokenSecret: Redacted.make("test-token-key"),
      post: endpoint.post,
    });
  }),
).pipe(Layer.provideMerge(TestAppleEndpoint.layer));
