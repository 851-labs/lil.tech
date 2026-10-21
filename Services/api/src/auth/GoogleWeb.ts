import { Context, Effect, Layer, Option, Redacted, Schema } from "effect";
import { GoogleClients } from "./Google.ts";

// Sign in with Google on the agents' authorization page (851-2850): the authorization code flow
// with PKCE, with the Web application client in `googleClientIds.web`. Its code is redeemed here,
// with the client's secret, for the ID token that `GoogleSignIn` checks.

/** Google's sign-in page. */
export const googleAuthorizeUrl = "https://accounts.google.com/o/oauth2/v2/auth";

/** Where Google's sign-in page is: the CSP's `form-action` names it, for the redirect to it. */
export const googleWebOrigin = "https://accounts.google.com";

/** Google's token endpoint. */
const googleTokenUrl = "https://oauth2.googleapis.com/token";

/** How long redeeming a code may take: the person waits for it. */
const googleTimeout = "5 seconds";

export class GoogleCodeRedemptionFailed extends Schema.TaggedError<GoogleCodeRedemptionFailed>()(
  "GoogleCodeRedemptionFailed",
  {
    message: Schema.String,
    /** Google's `error`, if it answered with one, e.g. `invalid_grant`. */
    googleError: Schema.optionalKey(Schema.String),
    /**
     * Whether Google couldn't be reached or failed (a timeout, a network error, a 5xx), so trying
     * again later can work, rather than refusing the code.
     */
    unavailable: Schema.Boolean,
  },
) {}

/** POSTs a form to Google's token endpoint: `fetch`, swapped in tests. */
export type GooglePost = (
  form: Readonly<Record<string, string>>,
  signal: AbortSignal,
) => Promise<{ readonly status: number; readonly body: string }>;

const fetchPost: GooglePost = async (form, signal) => {
  const response = await fetch(googleTokenUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
    signal,
  });
  return { status: response.status, body: await response.text() };
};

const TokenResponse = Schema.fromJsonString(Schema.Struct({ id_token: Schema.NonEmptyString }));

const ErrorResponse = Schema.fromJsonString(Schema.Struct({ error: Schema.String }));

/** The authorization page's Google client, where it's set up. */
export class GoogleWebClient extends Context.Service<
  GoogleWebClient,
  {
    /**
     * The client's ID, if Google sign-in on the web is set up here: the client is listed in
     * `googleClientIds.web` and the deploy bound its secret. Without it, the page has no Google
     * button.
     */
    readonly clientId: Option.Option<string>;
    /** Redeems an authorization code for Google's ID token, which isn't checked yet. */
    readonly redeem: (input: {
      readonly code: string;
      readonly codeVerifier: string;
      readonly redirectUri: string;
    }) => Effect.Effect<string, GoogleCodeRedemptionFailed>;
  }
>()("lil/api/auth/GoogleWebClient") {
  /** With the client's secret, if the deploy has one (staging and prod). */
  static layer(options: {
    readonly clientSecret: Option.Option<Redacted.Redacted<string>>;
    readonly post?: GooglePost;
  }) {
    return Layer.effect(
      GoogleWebClient,
      Effect.gen(function* () {
        const clients = yield* GoogleClients;
        const post = options.post ?? fetchPost;
        const configured = Option.all({
          clientId: Option.fromNullishOr(clients.web[0]),
          secret: options.clientSecret,
        });
        return GoogleWebClient.of({
          clientId: Option.map(configured, ({ clientId }) => clientId),
          redeem: Effect.fn("GoogleWebClient.redeem")(function* ({
            code,
            codeVerifier,
            redirectUri,
          }) {
            if (Option.isNone(configured)) {
              return yield* new GoogleCodeRedemptionFailed({
                message: "Google sign-in on the web isn't set up here",
                unavailable: true,
              });
            }
            const { clientId, secret } = configured.value;
            const response = yield* Effect.tryPromise({
              // The timeout aborts the request.
              try: (signal) =>
                post(
                  {
                    grant_type: "authorization_code",
                    code,
                    code_verifier: codeVerifier,
                    redirect_uri: redirectUri,
                    client_id: clientId,
                    client_secret: Redacted.value(secret),
                  },
                  signal,
                ),
              catch: (error) =>
                new GoogleCodeRedemptionFailed({
                  message: `Google's token endpoint: ${String(error)}`,
                  unavailable: true,
                }),
            }).pipe(
              Effect.timeoutOrElse({
                duration: googleTimeout,
                orElse: () =>
                  Effect.fail(
                    new GoogleCodeRedemptionFailed({
                      message: "Google's token endpoint timed out",
                      unavailable: true,
                    }),
                  ),
              }),
            );
            if (response.status !== 200) {
              const googleError = Option.getOrUndefined(
                Option.map(
                  Schema.decodeUnknownOption(ErrorResponse)(response.body),
                  (e) => e.error,
                ),
              );
              return yield* new GoogleCodeRedemptionFailed({
                message:
                  `Google's token endpoint answered ${response.status} ${googleError ?? ""}`.trim(),
                ...(googleError === undefined ? {} : { googleError }),
                unavailable: response.status >= 500,
              });
            }
            const tokens = yield* Schema.decodeUnknownEffect(TokenResponse)(response.body).pipe(
              Effect.mapError(
                () =>
                  new GoogleCodeRedemptionFailed({
                    message: "Google's token response has no ID token",
                    unavailable: false,
                  }),
              ),
            );
            return tokens.id_token;
          }),
        });
      }),
    );
  }
}
