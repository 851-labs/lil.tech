import { Clock, Duration, Effect, Option, Schema } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import type { SqlError } from "effect/sql";
import { AppleSignIn, appleWebServicesId } from "../auth/Apple.ts";
import { appleWebOrigin, maxAppleWebPostBytes } from "../auth/AppleWebSignIn.ts";
import { devSignInEnvironments, maxDevUsers, testAccount } from "../auth/DevSignIn.ts";
import { GoogleSignIn } from "../auth/Google.ts";
import { googleAuthorizeUrl, GoogleWebClient, googleWebOrigin } from "../auth/GoogleWeb.ts";
import { base64url, sha256Hex } from "../auth/Tokens.ts";
import { AgentGrants, type PendingAuthorization } from "../core/AgentGrants.ts";
import { agentsConsentPolicyVersions, Consents } from "../core/Consents.ts";
import { Identities } from "../core/Identities.ts";
import { AgentAuthorizationId, newAgentAuthorizationId } from "../core/Ids.ts";
import { type OAuthClient, OAuthClients } from "../core/OAuthClients.ts";
import { Users } from "../core/Users.ts";
import { stageDomains } from "../Deployment.ts";
import { checkAddressRateLimit, RateLimits, type TooManyRequests } from "../RateLimits.ts";
import type { Environment } from "../Status.ts";
import {
  agentAuthorizationLifetime,
  authorizationCodeLifetime,
  redirectHost,
} from "./AgentTokens.ts";
import {
  type AppView,
  type ClientView,
  consentPage,
  defaultTestAccount,
  errorPage,
  type FormBinding,
  formActionSource,
  maxAccountLength,
  pageResponse,
  SignInNotice,
  signInPage,
} from "./AuthorizationPages.ts";
import {
  type AgentHosts,
  type AgentResource,
  agentHosts,
  agentResources,
  resourceFor,
  resourceUrl,
} from "./Hosts.ts";
import { isLoopbackUri, matchesRedirectUri } from "./RedirectUris.ts";
import { queryOf, readForm, readParams, requestOrigin } from "./Requests.ts";

// The agents' authorization page (851-2849, `docs/decisions/accounts.md`, Agents):
// `GET /oauth/authorize` checks the request and binds it to the browser, the user signs in, then
// allows the agent (or not), and the browser goes back to the agent with a code. Every step is
// bound to the browser that started it by a `__Host-` cookie whose hash the authorization keeps,
// and every form carries a CSRF token derived from that cookie, so nobody can finish someone
// else's request or slip theirs into someone else's browser (login CSRF).
//
// Staging and prod sign in with Apple or Google (851-2850), on their web pages, for accounts that
// already exist: nothing is created here. Each sign-in's `state` names the request and carries a
// random secret whose hash the request keeps, with the nonce its ID token must carry. Apple posts
// its answer cross-site, which a `SameSite=Lax` cookie doesn't come with, so its callback finds the
// request by `state` alone. So an answer only records whose account it was, and sends the browser
// that brought it to finish signing in with a one-time ticket, where the cookie is checked: the
// account goes to the request only if that browser started it. Google's answer is a redirect,
// which does bring the cookie (checked there too), and its PKCE verifier is derived from it.

/** Where Apple and Google sign in (`providerSignIn`): only these hosts can be registered with them. */
export const providerSignInEnvironments: ReadonlySet<Environment> = new Set(["staging", "prod"]);

/** Where Apple posts its sign-in's answer, on the issuer's host. */
export const appleCallbackPath = "/oauth/apple/callback";

/** Where Google redirects with its sign-in's answer, on the issuer's host. */
export const googleCallbackPath = "/oauth/google/callback";

/** Where a provider's answer sends the browser to finish signing in, with its ticket. */
const signedInPath = "/oauth/authorize/signed-in";

/** Apple's sign-in page. */
const appleAuthorizeUrl = "https://appleid.apple.com/auth/authorize";

/**
 * The cookie that binds an authorization request to the browser that started it: one per request,
 * so a browser can have two going at once (two agents connecting, or one that opened the page
 * twice), and finishing one leaves the other.
 */
export const browserCookie = (id: AgentAuthorizationId) => `__Host-lil-agent-auth-${id}`;

/** The largest form the authorization page reads. */
const maxPageFormBytes = 4 * 1024;

/** The longest `state` a client may send, which is kept and sent back. */
export const maxStateLength = 1000;

/** An S256 PKCE challenge: a SHA-256, base64url-encoded without padding (RFC 7636 §4.2). */
const s256Challenge = /^[A-Za-z0-9_-]{43}$/;

/**
 * A request that can't go back to the agent, shown as a page: an unknown client or redirect URI
 * (RFC 6749 §4.1.2.1), or a step that isn't this browser's or has expired.
 */
class PageError extends Schema.TaggedError<PageError>()("PageError", {
  status: Schema.Number,
  title: Schema.String,
  message: Schema.String,
}) {}

/** A request the agent should hear about: a redirect to it with `error` (RFC 6749 §4.1.2.1). */
class RedirectError extends Schema.TaggedError<RedirectError>()("RedirectError", {
  redirectUri: Schema.String,
  state: Schema.NullOr(Schema.String),
  error: Schema.Literals(["invalid_request", "unsupported_response_type", "invalid_target"]),
  description: Schema.String,
}) {}

const pageError = (status: number, title: string, message: string) =>
  new PageError({ status, title, message });

/** A step whose request has expired, finished, or belongs to another browser. */
const notThisBrowser = pageError(
  400,
  "This request can't continue",
  "It has expired, was already answered, or was started in another browser. Connections must " +
    "finish within 10 minutes, in the browser the agent opened.",
);

const alreadyAnswered = pageError(
  400,
  "This request was already answered",
  "The agent already has its answer.",
);

/** The redirect back to the agent, with `params`, `state` and the issuer (RFC 9207). */
const backToAgent = (
  redirectUri: string,
  params: Readonly<Record<string, string>>,
  state: string | null,
  issuer: string,
  status: 302 | 303,
) => {
  const url = new URL(redirectUri);
  for (const [name, value] of Object.entries(params)) url.searchParams.set(name, value);
  if (state !== null) url.searchParams.set("state", state);
  url.searchParams.set("iss", issuer);
  return HttpServerResponse.redirect(url, {
    status,
    headers: { "cache-control": "no-store", "referrer-policy": "no-referrer" },
  });
};

/** Sets a request's browser cookie, or (with `null`) expires it. */
const withBrowserCookie = (id: AgentAuthorizationId, value: string | null) =>
  HttpServerResponse.setCookieUnsafe(browserCookie(id), value ?? "", {
    path: "/",
    secure: true,
    httpOnly: true,
    sameSite: "lax",
    maxAge: Duration.millis(value === null ? 0 : agentAuthorizationLifetime),
  });

/** A new cookie value: 32 random bytes. */
const newBrowserSecret = Effect.sync(() => base64url(crypto.getRandomValues(new Uint8Array(32))));

/** An HMAC of `purpose` and a request's ID, keyed by the browser's cookie. */
const fromCookie = (cookie: string, purpose: "csrf" | "code" | "pkce", id: AgentAuthorizationId) =>
  Effect.promise(async () => {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(cookie),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${purpose}:${id}`));
    return base64url(new Uint8Array(mac));
  });

/** The CSRF token for a request's forms. */
const csrfToken = (cookie: string, id: AgentAuthorizationId) => fromCookie(cookie, "csrf", id);

/**
 * A request's authorization code, from its browser's cookie, so allowing it twice (a double click,
 * whose second response is the one the browser shows) sends the agent the same code again.
 */
const authorizationCode = (cookie: string, id: AgentAuthorizationId) =>
  Effect.map(fromCookie(cookie, "code", id), (mac) => `lmc_${mac}`);

/** The PKCE verifier for a request's Google sign-in, from its browser's cookie (43 characters). */
const googleCodeVerifier = (cookie: string, id: AgentAuthorizationId) =>
  fromCookie(cookie, "pkce", id);

/** A PKCE S256 challenge for `verifier` (RFC 7636 §4.2). */
const s256 = (verifier: string) =>
  Effect.promise(async () =>
    base64url(
      new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))),
    ),
  );

/** A sign-in's `state`: the request's ID, and a secret only the request's hash of it matches. */
const newSignInState = (id: AgentAuthorizationId) =>
  Effect.sync(() => `${id}.${base64url(crypto.getRandomValues(new Uint8Array(32)))}`);

/** The request a sign-in's `state` names, if it names one. */
const requestOfState = (state: string | undefined) =>
  Schema.decodeUnknownOption(AgentAuthorizationId)(state?.split(".", 1)[0]);

/** A provider's answer that isn't a request's: unknown, used, replaced, or expired. */
const badSignIn = pageError(
  400,
  "This sign-in can't continue",
  "It has expired, was already used, or was started again. Connections must finish within 10 " +
    "minutes, in the browser the agent opened.",
);

/** Compares two strings in time that depends only on their lengths. */
const constantTimeEquals = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
};

const clientView = (
  client: { readonly name: string | null; readonly kind: "cimd" | "dcr"; readonly id: string },
  redirectUri: string,
): ClientView => ({
  name: client.name,
  kind: client.kind,
  domain: client.kind === "cimd" ? new URL(client.id).hostname : null,
  redirectHost: redirectHost(redirectUri),
  loopback: isLoopbackUri(redirectUri),
});

const pendingClientView = (pending: PendingAuthorization) =>
  clientView(
    { name: pending.clientName, kind: pending.clientKind, id: pending.clientId },
    pending.redirectUri,
  );

/** A checked authorization request, ready to store. */
interface CheckedRequest {
  readonly client: OAuthClient;
  readonly redirectUri: string;
  readonly state: string | null;
  readonly codeChallenge: string;
  readonly resource: AgentResource;
  readonly scopes: ReadonlyArray<string>;
}

/**
 * Checks `GET /oauth/authorize`'s query (RFC 6749 §4.1.1, RFC 7636, RFC 8707). A bad client or
 * redirect URI is a page, never a redirect; anything else goes back to the agent.
 */
const checkRequest = Effect.fnUntraced(function* (
  query: string,
  hosts: AgentHosts,
  clients: OAuthClients["Service"],
): Effect.fn.Return<CheckedRequest, PageError | RedirectError> {
  // Every value given, so a parameter given twice is caught even when one is empty. One without a
  // value counts as absent (RFC 6749 §3.1).
  const values = new Map<string, Array<string>>();
  for (const [name, value] of new URLSearchParams(query)) {
    values.set(name, [...(values.get(name) ?? []), value]);
  }
  const one = (name: string) => {
    const given = values.get(name) ?? [];
    return given.length === 1 && given[0] !== "" ? Option.some(given[0] ?? "") : Option.none();
  };
  const invalid = (title: string, message: string) => pageError(400, title, message);

  const clientId = one("client_id");
  if (Option.isNone(clientId)) {
    return yield* invalid("This request is missing its agent", "It has no single client_id.");
  }
  const client = yield* clients.resolve(clientId.value).pipe(
    Effect.catchTags({
      InvalidClient: (error) =>
        Effect.fail(invalid("This agent isn't recognized", error.description)),
      SqlError: Effect.die,
    }),
  );
  const redirectUri = one("redirect_uri");
  if (Option.isNone(redirectUri)) {
    return yield* invalid(
      "This request is missing its return address",
      "It has no single redirect_uri.",
    );
  }
  if (!matchesRedirectUri(client.redirectUris, redirectUri.value)) {
    return yield* invalid(
      "This request's return address isn't the agent's",
      "Its redirect_uri isn't one the agent registered, so lil won't send you there.",
    );
  }

  const state = one("state");
  const fail = (error: RedirectError["error"], description: string, keepState = true) =>
    new RedirectError({
      redirectUri: redirectUri.value,
      state: keepState ? Option.getOrNull(state) : null,
      error,
      description,
    });
  for (const [name, given] of values) {
    if (given.length > 1) {
      return yield* fail(
        name === "resource" ? "invalid_target" : "invalid_request",
        `${name} is given more than once`,
      );
    }
  }
  if (Option.isSome(state) && state.value.length > maxStateLength) {
    return yield* fail("invalid_request", `state is longer than ${maxStateLength}`, false);
  }
  const responseType = one("response_type");
  if (Option.isNone(responseType))
    return yield* fail("invalid_request", "response_type is missing");
  if (responseType.value !== "code") {
    return yield* fail("unsupported_response_type", "Only the code flow is supported");
  }
  const challenge = one("code_challenge");
  if (Option.isNone(challenge)) {
    return yield* fail("invalid_request", "code_challenge is missing: PKCE is required");
  }
  if (Option.getOrUndefined(one("code_challenge_method")) !== "S256") {
    return yield* fail("invalid_request", "code_challenge_method must be S256");
  }
  if (!s256Challenge.test(challenge.value)) {
    return yield* fail("invalid_request", "code_challenge isn't an S256 challenge");
  }
  const asked = one("resource");
  // Without a resource, the health server is assumed while it's the only one.
  const resource = Option.isNone(asked)
    ? Option.some("health" as const)
    : resourceFor(hosts, asked.value);
  if (Option.isNone(resource)) {
    return yield* fail("invalid_target", `The resource isn't one of lil's MCP servers`);
  }
  // Scopes the app's server doesn't have (another app's, or unknown) are dropped, and none at all
  // means all of the app's.
  const known: ReadonlyArray<string> = agentResources[resource.value].scopes;
  const scopes = [
    ...new Set(
      Option.getOrElse(one("scope"), () => "")
        .split(" ")
        .filter((scope) => known.includes(scope)),
    ),
  ];
  return {
    client,
    redirectUri: redirectUri.value,
    state: Option.getOrNull(state),
    codeChallenge: challenge.value,
    resource: resource.value,
    scopes: scopes.length === 0 ? known : scopes,
  };
});

/** The privacy policy's URL on this stage's site. */
const privacyUrl = (environment: Environment) =>
  `https://${stageDomains[environment]?.site ?? "lil.tech"}/privacy`;

/**
 * `GET /oauth/authorize` and its steps, `POST /oauth/authorize/sign-in`,
 * `GET /oauth/authorize/consent` and `POST /oauth/authorize/decision`. Registered with the other
 * OAuth routes, only where agents may connect. No CORS: the page uses a cookie.
 */
export const addAuthorizationPage = (router: HttpRouter.HttpRouter, environment: Environment) =>
  Effect.gen(function* () {
    const grants = yield* AgentGrants;
    const clients = yield* OAuthClients;
    const consents = yield* Consents;
    const users = yield* Users;
    const identities = yield* Identities;
    const limits = yield* RateLimits;
    const apple = yield* AppleSignIn;
    const google = yield* GoogleSignIn;
    const googleWeb = yield* GoogleWebClient;
    const providerSignIn = providerSignInEnvironments.has(environment);
    const methods = {
      testAccounts: devSignInEnvironments.has(environment),
      apple: providerSignIn,
      google: providerSignIn && Option.isSome(googleWeb.clientId),
    };
    /** Where the sign-in page's forms may redirect: the agent, and Apple's and Google's pages. */
    const signInFormActions = (redirectUri: string) => [
      formActionSource(redirectUri),
      ...(methods.apple ? [appleWebOrigin] : []),
      ...(methods.google ? [googleWebOrigin] : []),
    ];

    const hostsOf = Effect.map(HttpServerRequest.HttpServerRequest, (request) =>
      agentHosts(environment, requestOrigin(request)),
    );

    /** The app a stored authorization is for, by its resource. */
    const appOf = (hosts: AgentHosts, pending: PendingAuthorization) =>
      Option.match(resourceFor(hosts, pending.resource), {
        onNone: () => Effect.fail(notThisBrowser),
        onSome: (key) => Effect.succeed(key),
      });
    const appView = (key: AgentResource): AppView => ({
      name: agentResources[key].name,
      privacyUrl: privacyUrl(environment),
    });

    /**
     * The authorization request `id`, if this browser started it and it hasn't expired, with the
     * CSRF token its forms carry.
     */
    const bound = (id: string | undefined) =>
      Effect.gen(function* () {
        const request = yield* HttpServerRequest.HttpServerRequest;
        const decoded = Schema.decodeUnknownOption(AgentAuthorizationId)(id);
        if (Option.isNone(decoded)) return yield* notThisBrowser;
        const cookie = request.cookies[browserCookie(decoded.value)];
        if (cookie === undefined || cookie === "") return yield* notThisBrowser;
        const now = yield* Clock.currentTimeMillis;
        const pending = yield* grants.findPendingAuthorization(decoded.value, now);
        if (Option.isNone(pending) || pending.value.browserHash !== (yield* sha256Hex(cookie))) {
          return yield* notThisBrowser;
        }
        const binding: FormBinding = {
          request: pending.value.id,
          csrf: yield* csrfToken(cookie, pending.value.id),
        };
        return { pending: pending.value, binding, cookie, now };
      });

    /** A posted step's form, if its CSRF token is its request's. */
    const posted = Effect.gen(function* () {
      const form = yield* readForm(maxPageFormBytes).pipe(
        Effect.mapError((error) => pageError(400, "This form couldn't be read", error.description)),
      );
      const step = yield* bound(form.get("request"));
      if (!constantTimeEquals(form.get("csrf") ?? "", step.binding.csrf)) {
        return yield* notThisBrowser;
      }
      return { ...step, form };
    });

    /**
     * The page for where a request is: sign-in (with `notice`, after a sign-in that didn't work),
     * or consent once someone has signed in.
     */
    const stepPage = (
      hosts: AgentHosts,
      pending: PendingAuthorization,
      binding: FormBinding,
      notice: SignInNotice | undefined,
    ) =>
      Effect.gen(function* () {
        if (pending.decided) return yield* alreadyAnswered;
        const app = appView(yield* appOf(hosts, pending));
        const client = pendingClientView(pending);
        if (pending.userId === null) {
          return pageResponse(signInPage({ client, app, binding, methods, notice }), {
            formActions: signInFormActions(pending.redirectUri),
          });
        }
        const html = consentPage({
          client,
          app,
          binding,
          account: pending.userName ?? "your account",
        });
        return pageResponse(html, { formActions: [formActionSource(pending.redirectUri)] });
      });

    /** The redirect to a request's page, after signing in (or not), with a `notice`. */
    const toStep = (id: AgentAuthorizationId, notice?: SignInNotice) =>
      HttpServerResponse.redirect(
        `/oauth/authorize/consent?request=${encodeURIComponent(id)}` +
          (notice === undefined ? "" : `&notice=${notice}`),
        { status: 303, headers: { "cache-control": "no-store", "referrer-policy": "no-referrer" } },
      );

    /**
     * Records that the identity `provider` and `subject` answered a request's sign-in (the one
     * whose state hashes to `stateHash`), if an account has it, and sends the browser that brought
     * the answer to finish signing in, with a ticket. Finishing also needs the request's cookie, so
     * the account goes to a request only when one browser both started it and signed in: someone
     * who sends their sign-in link (with their `state`) to someone else gets neither.
     */
    const answerSignIn = (
      pending: PendingAuthorization,
      stateHash: string,
      provider: "apple" | "google",
      subject: string,
      now: number,
    ) =>
      Effect.gen(function* () {
        const identity = yield* identities.find(provider, subject);
        if (Option.isNone(identity)) return toStep(pending.id, `${provider}_unknown`);
        const ticket = yield* newBrowserSecret;
        const answered = yield* grants.answerProviderSignIn(
          pending.id,
          stateHash,
          { userId: identity.value.userId, ticketHash: yield* sha256Hex(ticket) },
          now,
        );
        // Started again, signed in another way or decided, since its state was checked.
        if (!answered) return toStep(pending.id, "failed");
        return HttpServerResponse.redirect(
          `${signedInPath}?request=${encodeURIComponent(pending.id)}` +
            `&ticket=${encodeURIComponent(ticket)}`,
          {
            status: 303,
            headers: { "cache-control": "no-store", "referrer-policy": "no-referrer" },
          },
        );
      });

    /**
     * The request a provider's answer is for, with its sign-in's state hash and nonce: the request
     * its `state` names (`pending`, if it's already read), waiting for this provider's sign-in
     * with that state.
     */
    const awaitingAnswer = (
      provider: "apple" | "google",
      state: string | undefined,
      now: number,
      read?: PendingAuthorization,
    ) =>
      Effect.gen(function* () {
        const id = requestOfState(state);
        if (Option.isNone(id) || state === undefined) return yield* badSignIn;
        const pending =
          read?.id === id.value
            ? read
            : Option.getOrUndefined(yield* grants.findPendingAuthorization(id.value, now));
        if (pending === undefined) return yield* badSignIn;
        const stateHash = yield* sha256Hex(state);
        if (
          pending.signInProvider !== provider ||
          pending.signInNonce === null ||
          !constantTimeEquals(pending.signInStateHash ?? "", stateHash)
        ) {
          return yield* badSignIn;
        }
        return { pending, stateHash, nonce: pending.signInNonce };
      });

    /** What a provider's ID token that didn't sign in says to the person. */
    const signInFailed = (id: AgentAuthorizationId) => ({
      InvalidIdentityToken: (error: { readonly message: string }) =>
        Effect.logWarning("Signing in to an agent's authorization failed", error.message).pipe(
          Effect.as(toStep(id, "failed")),
        ),
      SignInUnavailable: (error: { readonly message: string }) =>
        Effect.logWarning(
          "Signing in to an agent's authorization is unavailable",
          error.message,
        ).pipe(Effect.as(toStep(id, "unavailable"))),
    });

    /** Answers the page's errors: a page, or a redirect back to the agent. */
    const answerErrors = <R>(
      effect: Effect.Effect<
        HttpServerResponse.HttpServerResponse,
        PageError | RedirectError | TooManyRequests | SqlError.SqlError,
        R
      >,
    ) =>
      effect.pipe(
        Effect.catchTags({
          PageError: (error: PageError) =>
            Effect.succeed(
              pageResponse(errorPage(error.title, error.message), { status: error.status }),
            ),
          RedirectError: (error: RedirectError) =>
            Effect.map(hostsOf, (hosts) =>
              backToAgent(
                error.redirectUri,
                { error: error.error, error_description: error.description },
                error.state,
                hosts.issuer,
                302,
              ),
            ),
          TooManyRequests: (error: TooManyRequests) =>
            Effect.succeed(
              pageResponse(errorPage("Too many attempts", "Wait a minute, then connect again."), {
                status: 429,
              }).pipe(HttpServerResponse.setHeader("retry-after", String(error.retryAfterSeconds))),
            ),
        }),
        Effect.orDie,
      );

    // Starts an authorization: checks it, stores it bound to a new cookie, and asks to sign in.
    // Counted against the sign-in limit, since each one is a write anyone can make.
    yield* router.add(
      "GET",
      "/oauth/authorize",
      Effect.gen(function* () {
        yield* checkAddressRateLimit(limits, "signIn");
        const request = yield* HttpServerRequest.HttpServerRequest;
        const hosts = yield* hostsOf;
        const checked = yield* checkRequest(queryOf(request.url), hosts, clients);
        const now = yield* Clock.currentTimeMillis;
        const cookie = yield* newBrowserSecret;
        const id = yield* newAgentAuthorizationId;
        yield* grants.createAuthorization({
          id,
          clientId: checked.client.clientId,
          redirectUri: checked.redirectUri,
          state: checked.state,
          codeChallenge: checked.codeChallenge,
          scopes: checked.scopes,
          resource: resourceUrl(hosts, checked.resource),
          browserHash: yield* sha256Hex(cookie),
          createdAt: now,
          expiresAt: now + agentAuthorizationLifetime,
        });
        const html = signInPage({
          client: clientView(
            { name: checked.client.name, kind: checked.client.kind, id: checked.client.clientId },
            checked.redirectUri,
          ),
          app: appView(checked.resource),
          binding: { request: id, csrf: yield* csrfToken(cookie, id) },
          methods,
        });
        return pageResponse(html, { formActions: signInFormActions(checked.redirectUri) }).pipe(
          withBrowserCookie(id, cookie),
        );
      }).pipe(answerErrors),
    );

    // The step a request is at, after signing in (the redirect after the post).
    yield* router.add(
      "GET",
      "/oauth/authorize/consent",
      Effect.gen(function* () {
        const query = yield* readParams(
          queryOf((yield* HttpServerRequest.HttpServerRequest).url),
        ).pipe(Effect.mapError(() => notThisBrowser));
        const { pending, binding } = yield* bound(query.get("request"));
        // Only the page's own notices: anything else is ignored.
        const notice = SignInNotice.find((known) => known === query.get("notice"));
        return yield* stepPage(yield* hostsOf, pending, binding, notice);
      }).pipe(answerErrors),
    );

    // Signs in: starts signing in with Apple or Google (`provider`, staging and prod), or signs in
    // to a test account (previews and `alchemy dev`), then shows consent.
    yield* router.add(
      "POST",
      "/oauth/authorize/sign-in",
      Effect.gen(function* () {
        yield* checkAddressRateLimit(limits, "signIn");
        const { pending, form, cookie, now } = yield* posted;
        const provider = form.get("provider");
        const unavailable = pageError(
          404,
          "Signing in isn't available here",
          "This stage has no sign-in on the web yet.",
        );
        const offered =
          provider === undefined
            ? methods.testAccounts
            : (provider === "apple" || provider === "google") && methods[provider];
        if (!offered) {
          return yield* unavailable;
        }
        if (pending.decided) return yield* alreadyAnswered;
        const consent = toStep(pending.id);
        if (pending.userId !== null) return consent;
        if (provider === "apple" || provider === "google") {
          const hosts = yield* hostsOf;
          const state = yield* newSignInState(pending.id);
          const nonce = yield* newBrowserSecret;
          const started = yield* grants.startProviderSignIn(
            pending.id,
            { provider, stateHash: yield* sha256Hex(state), nonce },
            now,
          );
          if (!started) return yield* notThisBrowser;
          // The provider's token carries the nonce's SHA-256, as the apps' do.
          const url = new URL(provider === "apple" ? appleAuthorizeUrl : googleAuthorizeUrl);
          const params: Record<string, string> =
            provider === "apple"
              ? {
                  client_id: appleWebServicesId,
                  redirect_uri: `${hosts.issuer}${appleCallbackPath}`,
                  // No scopes: only existing accounts sign in here, so no name or email.
                  response_type: "code id_token",
                  response_mode: "form_post",
                }
              : {
                  client_id: Option.getOrElse(googleWeb.clientId, () => ""),
                  redirect_uri: `${hosts.issuer}${googleCallbackPath}`,
                  response_type: "code",
                  scope: "openid email",
                  code_challenge: yield* s256(yield* googleCodeVerifier(cookie, pending.id)),
                  code_challenge_method: "S256",
                  prompt: "select_account",
                };
          for (const [name, value] of Object.entries({
            ...params,
            state,
            nonce: yield* sha256Hex(nonce),
          })) {
            url.searchParams.set(name, value);
          }
          return HttpServerResponse.redirect(url, {
            status: 303,
            headers: { "cache-control": "no-store", "referrer-policy": "no-referrer" },
          });
        }
        const account = (form.get("account") ?? defaultTestAccount).trim();
        if (account === "" || account.length > maxAccountLength) {
          return yield* pageError(
            400,
            "That test account name won't work",
            `Use a name of 1 to ${maxAccountLength} characters.`,
          );
        }
        const found = yield* testAccount(users, { account }).pipe(Effect.orDie);
        if (Option.isNone(found)) {
          return yield* pageError(
            429,
            "This preview is full",
            `It already has ${maxDevUsers} users, so it can't make another test account.`,
          );
        }
        const { user, made } = found.value;
        if (!(yield* grants.signInAuthorization(pending.id, user.id, now))) {
          if (made) yield* users.delete(user.id).pipe(Effect.ignore);
          return yield* notThisBrowser;
        }
        return consent;
      }).pipe(answerErrors),
    );

    if (providerSignIn) {
      // Finishes signing in with Apple or Google: the browser that brought the provider's answer,
      // with its ticket, and the request's cookie.
      yield* router.add(
        "GET",
        signedInPath,
        Effect.gen(function* () {
          const query = yield* readParams(
            queryOf((yield* HttpServerRequest.HttpServerRequest).url),
          ).pipe(Effect.mapError(() => notThisBrowser));
          const { pending, now } = yield* bound(query.get("request"));
          const finished = yield* grants.finishProviderSignIn(
            pending.id,
            yield* sha256Hex(query.get("ticket") ?? ""),
            now,
          );
          return toStep(pending.id, finished || pending.userId !== null ? undefined : "failed");
        }).pipe(answerErrors),
      );

      // Apple's answer, posted from its page (`response_mode=form_post`). Cross-site, so without
      // the cookie: the page it redirects to checks that.
      yield* router.add(
        "POST",
        appleCallbackPath,
        Effect.gen(function* () {
          yield* checkAddressRateLimit(limits, "signIn");
          const request = yield* HttpServerRequest.HttpServerRequest;
          const origin = request.headers["origin"];
          if (origin !== undefined && origin !== appleWebOrigin) return yield* badSignIn;
          const form = yield* readForm(maxAppleWebPostBytes).pipe(Effect.mapError(() => badSignIn));
          const now = yield* Clock.currentTimeMillis;
          const { pending, stateHash, nonce } = yield* awaitingAnswer(
            "apple",
            form.get("state"),
            now,
          );
          // Cancelled on Apple's page, or something went wrong there: back to signing in.
          const idToken = form.get("id_token");
          if (form.has("error") || idToken === undefined) return toStep(pending.id);
          return yield* apple.verify(idToken, nonce, undefined).pipe(
            Effect.flatMap((identity) =>
              // Apple signs it for the Services ID; the iPhone's App ID would be another sign-in.
              identity.clientId === appleWebServicesId
                ? answerSignIn(pending, stateHash, "apple", identity.subject, now)
                : Effect.succeed(toStep(pending.id, "failed")),
            ),
            Effect.catchTags(signInFailed(pending.id)),
          );
        }).pipe(answerErrors),
      );

      // Google's answer, a redirect with a code, which comes with the cookie.
      yield* router.add(
        "GET",
        googleCallbackPath,
        Effect.gen(function* () {
          yield* checkAddressRateLimit(limits, "signIn");
          const query = yield* readParams(
            queryOf((yield* HttpServerRequest.HttpServerRequest).url),
          ).pipe(Effect.mapError(() => badSignIn));
          const state = query.get("state");
          const step = yield* bound(Option.getOrUndefined(requestOfState(state))).pipe(
            Effect.catchTag("PageError", () => Effect.fail(badSignIn)),
          );
          const { cookie, now } = step;
          const { pending, stateHash, nonce } = yield* awaitingAnswer(
            "google",
            state,
            now,
            step.pending,
          );
          const code = query.get("code");
          if (query.has("error") || code === undefined) return toStep(pending.id);
          const hosts = yield* hostsOf;
          return yield* googleWeb
            .redeem({
              code,
              codeVerifier: yield* googleCodeVerifier(cookie, pending.id),
              redirectUri: `${hosts.issuer}${googleCallbackPath}`,
            })
            .pipe(
              Effect.flatMap((idToken) => google.verify(idToken, nonce, "web")),
              Effect.flatMap((identity) =>
                answerSignIn(pending, stateHash, "google", identity.subject, now),
              ),
              Effect.catchTags({
                ...signInFailed(pending.id),
                GoogleCodeRedemptionFailed: (error) =>
                  Effect.logWarning("Redeeming Google's code failed", error.message).pipe(
                    Effect.as(toStep(pending.id, error.unavailable ? "unavailable" : "failed")),
                  ),
              }),
            );
        }).pipe(answerErrors),
      );
    }

    // Allow or Cancel. Allow gives the request a code, records the app's agents consent, and sends
    // the browser back to the agent with the code. Either way, the cookie has done its job.
    yield* router.add(
      "POST",
      "/oauth/authorize/decision",
      Effect.gen(function* () {
        const { pending, form, cookie, now } = yield* posted;
        const hosts = yield* hostsOf;
        const decision = form.get("decision");
        if (decision === "cancel") {
          if (!(yield* grants.deleteUndecidedAuthorization(pending.id))) {
            return yield* alreadyAnswered;
          }
          return backToAgent(
            pending.redirectUri,
            { error: "access_denied", error_description: "The user didn't allow it" },
            pending.state,
            hosts.issuer,
            303,
          ).pipe(withBrowserCookie(pending.id, null));
        }
        if (decision !== "allow") {
          return yield* pageError(400, "This form couldn't be read", "It has no decision.");
        }
        const userId = pending.userId;
        if (userId === null) return yield* notThisBrowser;
        const key = yield* appOf(hosts, pending);
        const code = yield* authorizationCode(cookie, pending.id);
        const codeHash = yield* sha256Hex(code);
        // What this request's code is now: just given it, or as an earlier Allow left it.
        let current = {
          codeHash: pending.codeHash,
          codeExpiresAt: pending.codeExpiresAt,
          usedAt: pending.usedAt,
        };
        if (!pending.decided) {
          const approved = yield* grants.approveAuthorization({
            id: pending.id,
            userId,
            grantedScopes: pending.scopes,
            codeHash,
            codeExpiresAt: now + authorizationCodeLifetime,
            now,
          });
          if (approved) {
            current = { codeHash, codeExpiresAt: now + authorizationCodeLifetime, usedAt: null };
          } else {
            // Another Allow from this browser got there first (a double click).
            const again = yield* grants.findPendingAuthorization(pending.id, now);
            if (Option.isNone(again)) return yield* alreadyAnswered;
            current = again.value;
          }
        }
        // Allowing twice sends the same code again, while the agent hasn't used it: the browser
        // shows the last response, which mustn't lose the code.
        if (
          current.codeHash !== codeHash ||
          current.usedAt !== null ||
          (current.codeExpiresAt ?? 0) <= now
        ) {
          return yield* alreadyAnswered;
        }
        // Recorded once the request is allowed, so a request that wasn't has no consent. Granting
        // again keeps the first.
        const consent = agentResources[key].consent;
        yield* consents.grant(userId, consent, agentsConsentPolicyVersions[consent]);
        return backToAgent(pending.redirectUri, { code }, pending.state, hosts.issuer, 303).pipe(
          withBrowserCookie(pending.id, null),
        );
      }).pipe(answerErrors),
    );
  });
