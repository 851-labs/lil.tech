import { Clock, Duration, Effect, Option, Schema } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import type { SqlError } from "effect/sql";
import { devSignInEnvironments, maxDevUsers, testAccount } from "../auth/DevSignIn.ts";
import { base64url, newOpaqueToken, sha256Hex } from "../auth/Tokens.ts";
import { AgentGrants, type PendingAuthorization } from "../core/AgentGrants.ts";
import { agentsConsentPolicyVersions, Consents } from "../core/Consents.ts";
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
  errorPage,
  type FormBinding,
  formActionSource,
  pageResponse,
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
import { matchesRedirectUri } from "./RedirectUris.ts";
import { readForm, readParams, requestOrigin } from "./Requests.ts";

// The agents' authorization page (851-2849, `docs/decisions/accounts.md`, Agents):
// `GET /oauth/authorize` checks the request and binds it to the browser, the user signs in, then
// allows the agent (or not), and the browser goes back to the agent with a code. Every step is
// bound to the browser that started it by a `__Host-` cookie whose hash the authorization keeps,
// and every form carries a CSRF token derived from that cookie, so nobody can finish someone
// else's request or slip theirs into someone else's browser (login CSRF).

/** The cookie that binds an authorization request to the browser that started it. */
export const browserCookie = "__Host-lil-agent-auth";

/** The largest form the authorization page reads. */
const maxPageFormBytes = 4 * 1024;

/** The longest `state` a client may send, which is kept and sent back. */
export const maxStateLength = 1000;

/** The longest test account name. */
const maxAccountLength = 100;

/** The test account the sign-in suggests, which the apps' test-account sign-in also uses. */
export const defaultTestAccount = "e2e";

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

/** Sets the browser cookie, or (with `null`) expires it. */
const withBrowserCookie = (value: string | null) =>
  HttpServerResponse.setCookieUnsafe(browserCookie, value ?? "", {
    path: "/",
    secure: true,
    httpOnly: true,
    sameSite: "lax",
    maxAge: Duration.millis(value === null ? 0 : agentAuthorizationLifetime),
  });

/** A new cookie value: 32 random bytes. */
const newBrowserSecret = Effect.sync(() => base64url(crypto.getRandomValues(new Uint8Array(32))));

/** The CSRF token for a request's forms: an HMAC of its ID, keyed by the browser's cookie. */
const csrfToken = (cookie: string, id: AgentAuthorizationId) =>
  Effect.promise(async () => {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(cookie),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`csrf:${id}`));
    return base64url(new Uint8Array(mac));
  });

/** Compares two strings in time that depends only on their lengths. */
const constantTimeEquals = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
};

/** Whether `uri` is `http` to this machine, so a local program gets the code. */
const isLoopbackRedirect = (uri: string) => {
  const url = new URL(uri);
  return url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
};

const clientView = (
  client: { readonly name: string | null; readonly kind: "cimd" | "dcr"; readonly id: string },
  redirectUri: string,
): ClientView => ({
  name: client.name,
  kind: client.kind,
  domain: client.kind === "cimd" ? new URL(client.id).hostname : null,
  redirectHost: redirectHost(redirectUri),
  loopback: isLoopbackRedirect(redirectUri),
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
  const values = new Map<string, Array<string>>();
  for (const [name, value] of new URLSearchParams(query)) {
    if (value !== "") values.set(name, [...(values.get(name) ?? []), value]);
  }
  const one = (name: string) => {
    const given = values.get(name) ?? [];
    return given.length === 1 ? Option.some(given[0] ?? "") : Option.none();
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
    const limits = yield* RateLimits;
    const testAccounts = devSignInEnvironments.has(environment);

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
        const cookie = request.cookies[browserCookie];
        const decoded = Schema.decodeUnknownOption(AgentAuthorizationId)(id);
        if (cookie === undefined || cookie === "" || Option.isNone(decoded)) {
          return yield* notThisBrowser;
        }
        const now = yield* Clock.currentTimeMillis;
        const pending = yield* grants.findPendingAuthorization(decoded.value, now);
        if (Option.isNone(pending) || pending.value.browserHash !== (yield* sha256Hex(cookie))) {
          return yield* notThisBrowser;
        }
        const binding: FormBinding = {
          request: pending.value.id,
          csrf: yield* csrfToken(cookie, pending.value.id),
        };
        return { pending: pending.value, binding, now };
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

    /** The page for where a request is: sign-in, or consent once someone has signed in. */
    const stepPage = (hosts: AgentHosts, pending: PendingAuthorization, binding: FormBinding) =>
      Effect.gen(function* () {
        if (pending.decided) return yield* alreadyAnswered;
        const app = appView(yield* appOf(hosts, pending));
        const client = pendingClientView(pending);
        const html =
          pending.userId === null
            ? signInPage({ client, app, binding, testAccounts })
            : consentPage({
                client,
                app,
                binding,
                account: pending.userName ?? "your account",
              });
        return pageResponse(html, { formActions: [formActionSource(pending.redirectUri)] });
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
        const checked = yield* checkRequest(request.url.split("?")[1] ?? "", hosts, clients);
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
          testAccounts,
        });
        return pageResponse(html, { formActions: [formActionSource(checked.redirectUri)] }).pipe(
          withBrowserCookie(cookie),
        );
      }).pipe(answerErrors),
    );

    // The step a request is at, after signing in (the redirect after the post).
    yield* router.add(
      "GET",
      "/oauth/authorize/consent",
      Effect.gen(function* () {
        const query = yield* readParams(
          (yield* HttpServerRequest.HttpServerRequest).url.split("?")[1] ?? "",
        ).pipe(Effect.mapError(() => notThisBrowser));
        const { pending, binding } = yield* bound(query.get("request"));
        return yield* stepPage(yield* hostsOf, pending, binding);
      }).pipe(answerErrors),
    );

    // Signs in to a test account (previews and `alchemy dev` only), then shows consent.
    yield* router.add(
      "POST",
      "/oauth/authorize/sign-in",
      Effect.gen(function* () {
        yield* checkAddressRateLimit(limits, "signIn");
        const { pending, form, now } = yield* posted;
        if (!testAccounts) {
          return yield* pageError(
            404,
            "Signing in isn't available here",
            "This stage has no sign-in on the web yet.",
          );
        }
        if (pending.decided) return yield* alreadyAnswered;
        const consent = HttpServerResponse.redirect(
          `/oauth/authorize/consent?request=${encodeURIComponent(pending.id)}`,
          { status: 303, headers: { "cache-control": "no-store" } },
        );
        if (pending.userId !== null) return consent;
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

    // Allow or Cancel. Allow records the app's agents consent, then gives the request a code and
    // sends the browser back to the agent with it. Either way, the cookie has done its job.
    yield* router.add(
      "POST",
      "/oauth/authorize/decision",
      Effect.gen(function* () {
        const { pending, form, now } = yield* posted;
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
          ).pipe(withBrowserCookie(null));
        }
        if (decision !== "allow") {
          return yield* pageError(400, "This form couldn't be read", "It has no decision.");
        }
        if (pending.decided) return yield* alreadyAnswered;
        if (pending.userId === null) return yield* notThisBrowser;
        const key = yield* appOf(hosts, pending);
        const consent = agentResources[key].consent;
        yield* consents.grant(pending.userId, consent, agentsConsentPolicyVersions[consent]);
        const code = yield* newOpaqueToken("lmc");
        const approved = yield* grants.approveAuthorization({
          id: pending.id,
          userId: pending.userId,
          grantedScopes: pending.scopes,
          codeHash: yield* sha256Hex(code),
          codeExpiresAt: now + authorizationCodeLifetime,
          now,
        });
        if (!approved) return yield* alreadyAnswered;
        return backToAgent(pending.redirectUri, { code }, pending.state, hosts.issuer, 303).pipe(
          withBrowserCookie(null),
        );
      }).pipe(answerErrors),
    );
  });
