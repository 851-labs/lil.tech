import { assert, describe, it } from "@effect/vitest";
import { Effect, Option } from "effect";
import { eq } from "drizzle-orm";
import { agentsConsentPolicyVersions, Consents } from "../../src/core/Consents.ts";
import { CoreDb } from "../../src/core/CoreDb.ts";
import { agentAuthorizations } from "../../src/core/Schema.ts";
import { Users } from "../../src/core/Users.ts";
import type { Deployment } from "../../src/Deployment.ts";
import type { AgentAuthorizationId } from "../../src/core/Ids.ts";
import { browserCookie } from "../../src/oauth/AuthorizationPage.ts";
import { escape, formActionSource } from "../../src/oauth/AuthorizationPages.ts";
import { queryOf } from "../../src/oauth/Requests.ts";
import { type RateLimitCounter, RateLimits } from "../../src/RateLimits.ts";
import { type Handler, withApi } from "../TestApi.ts";
import { pkce, storeClaudeCode } from "./TestAgents.ts";

const preview: Deployment["Service"] = { environment: "preview", version: "1" };
const staging: Deployment["Service"] = { environment: "staging", version: "1" };
const prod: Deployment["Service"] = { environment: "prod", version: "1" };

/** A preview's one host, on workers.dev: the issuer and the MCP host. */
const origin = "https://lil-api-pr-12.example.workers.dev";

const redirectUri = "http://127.0.0.1:33418/oauth/callback";

const csp =
  "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' http://127.0.0.1:33418; " +
  "frame-ancestors 'none'";

const fetchWith = (handler: Handler, request: Request) =>
  Effect.promise(async () => {
    const response = await handler(request);
    return { response, html: await response.text() };
  });

/** Registers a client (DCR), as MCP Inspector does. */
const registerClient = (handler: Handler, name: unknown = "MCP Inspector") =>
  Effect.promise(async () => {
    const response = await handler(
      new Request(`${origin}/oauth/register`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ client_name: name, redirect_uris: [redirectUri] }),
      }),
    );
    return ((await response.json()) as { client_id: string }).client_id;
  });

/** An authorization request's query: S256 PKCE, with `overrides` (`undefined` leaves one out). */
const query = (clientId: string, overrides: Record<string, string | undefined> = {}) => {
  const { challenge, verifier } = pkce();
  const params: Record<string, string | undefined> = {
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state: "state-1",
    resource: `${origin}/health`,
    ...overrides,
  };
  const search = new URLSearchParams();
  for (const [name, value] of Object.entries(params)) {
    if (value !== undefined) search.set(name, value);
  }
  return { search: search.toString(), verifier };
};

/** The page's hidden fields, which bind its forms to the request. */
const binding = (html: string) => ({
  request: /name="request" value="([^"]+)"/.exec(html)?.[1] ?? "",
  csrf: /name="csrf" value="([^"]+)"/.exec(html)?.[1] ?? "",
});

/**
 * A browser starting an authorization: its cookie (as a `Cookie` header), and the sign-in page's
 * binding.
 */
const start = (handler: Handler, search: string, base = origin) =>
  Effect.gen(function* () {
    const { response, html } = yield* fetchWith(
      handler,
      new Request(`${base}/oauth/authorize?${search}`),
    );
    const setCookie = response.headers.get("set-cookie") ?? "";
    const cookie = /^(__Host-lil-agent-auth-[^=;]+=[^;]+)/.exec(setCookie)?.[1] ?? "";
    return { response, html, setCookie, cookie, ...binding(html) };
  });

const post = (
  handler: Handler,
  path: string,
  fields: Record<string, string>,
  cookie: string | null,
  base = origin,
) =>
  fetchWith(
    handler,
    new Request(`${base}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        ...(cookie === null ? {} : { cookie }),
      },
      body: new URLSearchParams(fields).toString(),
      redirect: "manual",
    }),
  );

const getConsent = (handler: Handler, request: string, cookie: string | null) =>
  fetchWith(
    handler,
    new Request(`${origin}/oauth/authorize/consent?request=${request}`, {
      headers: cookie === null ? {} : { cookie },
    }),
  );

/** Where a redirect goes, parsed. */
const location = (response: Response) => new URL(response.headers.get("location") ?? "", origin);

/** Starts, signs in to `account` and returns the consent page's binding. */
const signedIn = (handler: Handler, search: string, account = "e2e") =>
  Effect.gen(function* () {
    const started = yield* start(handler, search);
    const signIn = yield* post(
      handler,
      "/oauth/authorize/sign-in",
      { request: started.request, csrf: started.csrf, account },
      started.cookie,
    );
    assert.strictEqual(signIn.response.status, 303);
    const consent = yield* getConsent(handler, started.request, started.cookie);
    assert.strictEqual(consent.response.status, 200);
    return { ...started, consent, binding: binding(consent.html) };
  });

const decide = (
  handler: Handler,
  started: { readonly cookie: string; readonly binding: ReturnType<typeof binding> },
  decision: "allow" | "cancel",
) =>
  post(handler, "/oauth/authorize/decision", { ...started.binding, decision }, started.cookie).pipe(
    Effect.map(({ response }) => response),
  );

const exchangeCode = (handler: Handler, clientId: string, code: string, verifier: string) =>
  Effect.promise(async () => {
    const response = await handler(
      new Request(`${origin}/oauth/token`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          client_id: clientId,
          code,
          redirect_uri: redirectUri,
          code_verifier: verifier,
          resource: `${origin}/health`,
        }).toString(),
      }),
    );
    return { status: response.status, body: (await response.json()) as Record<string, unknown> };
  });

describe("The authorization page", () => {
  it.live("signs in to a test account, asks for consent and returns a code for health:read", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          // Another app's scope and an unknown one are dropped.
          const { search, verifier } = query(clientId, { scope: "health:read mail:read openid" });
          const started = yield* start(handler, search);
          assert.strictEqual(started.response.status, 200);
          assert.include(started.html, "Sign in to a Test Account");
          assert.include(started.html, 'value="e2e"');
          // The cookie that binds the request to this browser.
          assert.isTrue(
            started.setCookie.startsWith(
              `${browserCookie(started.request as AgentAuthorizationId)}=`,
            ),
          );
          for (const attribute of ["Max-Age=600", "Path=/", "HttpOnly", "Secure", "SameSite=Lax"]) {
            assert.include(started.setCookie, attribute);
          }
          assert.notInclude(started.setCookie, "Domain");

          const signIn = yield* post(
            handler,
            "/oauth/authorize/sign-in",
            { request: started.request, csrf: started.csrf, account: "e2e" },
            started.cookie,
          );
          assert.strictEqual(signIn.response.status, 303);
          assert.strictEqual(
            signIn.response.headers.get("location"),
            `/oauth/authorize/consent?request=${started.request}`,
          );
          const consent = yield* getConsent(handler, started.request, started.cookie);
          assert.strictEqual(consent.response.status, 200);
          assert.include(consent.html, "Allow MCP Inspector to read your lil health data?");
          assert.include(consent.html, "all of your lil health data");
          assert.include(consent.html, "Agents may send what they read to their AI provider");
          assert.include(consent.html, "https://lil.tech/privacy");
          assert.include(consent.html, "Signed in as <strong>e2e</strong>");
          assert.include(consent.html, "Unverified");
          assert.include(consent.html, "Returns you to <strong>127.0.0.1</strong>");
          assert.include(consent.html, "a program on this computer");

          const allowed = yield* decide(
            handler,
            { cookie: started.cookie, binding: binding(consent.html) },
            "allow",
          );
          assert.strictEqual(allowed.status, 303);
          const back = location(allowed);
          assert.strictEqual(`${back.origin}${back.pathname}`, redirectUri);
          assert.strictEqual(back.searchParams.get("state"), "state-1");
          assert.strictEqual(back.searchParams.get("iss"), origin);
          const code = back.searchParams.get("code") ?? "";
          assert.match(code, /^lmc_/);
          // The cookie has done its job.
          assert.include(allowed.headers.get("set-cookie") ?? "", "Max-Age=0");

          const tokens = yield* exchangeCode(handler, clientId, code, verifier);
          assert.strictEqual(tokens.status, 200);
          assert.strictEqual(tokens.body["scope"], "health:read");
          assert.match(String(tokens.body["access_token"]), /^lma_/);

          // Allowing recorded the app's agents consent, not Health's.
          const user = yield* Users.use((users) => users.findSynthetic("e2e"));
          assert.isTrue(Option.isSome(user));
          const userId = Option.getOrThrow(user).id;
          const given = yield* Consents.use((consents) =>
            consents.current(userId, "agents:health"),
          );
          assert.strictEqual(
            Option.getOrThrow(given).policyVersion,
            agentsConsentPolicyVersions["agents:health"],
          );
          assert.isTrue(
            Option.isNone(yield* Consents.use((consents) => consents.current(userId, "health"))),
          );
        }).pipe(Effect.orDie),
      preview,
    ),
  );

  it.live("sends pages with a strict CSP, no referrer and no CORS", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const { response } = yield* fetchWith(
            handler,
            new Request(`${origin}/oauth/authorize?${query(clientId).search}`, {
              headers: { origin: "https://evil.example" },
            }),
          );
          assert.strictEqual(response.headers.get("content-security-policy"), csp);
          assert.strictEqual(response.headers.get("referrer-policy"), "no-referrer");
          assert.strictEqual(response.headers.get("cache-control"), "no-store");
          assert.strictEqual(response.headers.get("content-type"), "text/html; charset=utf-8");
          assert.isNull(response.headers.get("access-control-allow-origin"));
          const preflight = yield* fetchWith(
            handler,
            new Request(`${origin}/oauth/authorize`, {
              method: "OPTIONS",
              headers: { origin: "https://evil.example", "access-control-request-method": "GET" },
            }),
          );
          assert.isNull(preflight.response.headers.get("access-control-allow-origin"));
        }),
      preview,
    ),
  );

  it.live("shows an error page, never a redirect, for a bad client or redirect URI", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          for (const overrides of [
            { client_id: undefined },
            { client_id: "cli_01jbunknownunknownunknownun" },
            { redirect_uri: undefined },
            { redirect_uri: "https://evil.example/callback" },
            { redirect_uri: "http://127.0.0.1:33418/other" },
          ]) {
            const { response, html } = yield* fetchWith(
              handler,
              new Request(`${origin}/oauth/authorize?${query(clientId, overrides).search}`),
            );
            assert.strictEqual(response.status, 400, JSON.stringify(overrides));
            assert.isNull(response.headers.get("location"));
            assert.isNull(response.headers.get("set-cookie"));
            assert.include(html, "connect again from your agent");
          }
          // A loopback redirect URI's port may change, as Claude Code's does.
          const otherPort = yield* start(
            handler,
            query(clientId, { redirect_uri: "http://127.0.0.1:50111/oauth/callback" }).search,
          );
          assert.strictEqual(otherPort.response.status, 200);
        }),
      preview,
    ),
  );

  it.live("sends other errors back to the agent, with state and iss", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const cases: ReadonlyArray<readonly [Record<string, string | undefined>, string]> = [
            [{ response_type: undefined }, "invalid_request"],
            [{ response_type: "token" }, "unsupported_response_type"],
            [{ code_challenge: undefined }, "invalid_request"],
            [{ code_challenge_method: undefined }, "invalid_request"],
            [{ code_challenge_method: "plain" }, "invalid_request"],
            [{ code_challenge: "too-short" }, "invalid_request"],
            [{ resource: "https://mcp.lil.tech/health" }, "invalid_target"],
            [{ resource: `${origin}/mail` }, "invalid_target"],
            [{ resource: `${origin}/health?x=1` }, "invalid_target"],
            // Exactly the resource's URL: the token endpoint compares it as a string.
            [{ resource: `${origin}/health/` }, "invalid_target"],
          ];
          for (const [overrides, error] of cases) {
            const { response } = yield* fetchWith(
              handler,
              new Request(`${origin}/oauth/authorize?${query(clientId, overrides).search}`),
            );
            assert.strictEqual(response.status, 302, JSON.stringify(overrides));
            const back = location(response);
            assert.strictEqual(`${back.origin}${back.pathname}`, redirectUri);
            assert.strictEqual(back.searchParams.get("error"), error, JSON.stringify(overrides));
            assert.strictEqual(back.searchParams.get("state"), "state-1");
            assert.strictEqual(back.searchParams.get("iss"), origin);
            assert.isNull(response.headers.get("set-cookie"));
          }
          // A parameter given twice.
          const twice = yield* fetchWith(
            handler,
            new Request(`${origin}/oauth/authorize?${query(clientId).search}&scope=a&scope=b`),
          );
          assert.strictEqual(location(twice.response).searchParams.get("error"), "invalid_request");
        }),
      preview,
    ),
  );

  it.live("takes the health server when there's no resource", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const db = yield* CoreDb;
          for (const resource of [undefined, `${origin}/health`]) {
            const started = yield* start(handler, query(clientId, { resource }).search);
            assert.strictEqual(started.response.status, 200);
            const [row] = yield* db
              .select({
                resource: agentAuthorizations.resource,
                scopes: agentAuthorizations.scopes,
              })
              .from(agentAuthorizations)
              .where(eq(agentAuthorizations.id, started.request as never));
            assert.deepStrictEqual(row, { resource: `${origin}/health`, scopes: ["health:read"] });
          }
        }).pipe(Effect.orDie),
      preview,
    ),
  );

  it.live("only lets the browser that started a request finish it", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const mine = yield* start(handler, query(clientId).search);
          // Another browser, with its own request and cookie.
          const theirs = yield* start(handler, query(clientId).search);
          const fields = { request: mine.request, csrf: mine.csrf, account: "e2e" };
          const myCookie = browserCookie(mine.request as AgentAuthorizationId);
          for (const cookie of [
            null,
            theirs.cookie,
            `${myCookie}=forged`,
            // Their cookie's value under my request's name.
            `${myCookie}=${theirs.cookie.split("=")[1]}`,
          ]) {
            const signIn = yield* post(handler, "/oauth/authorize/sign-in", fields, cookie);
            assert.strictEqual(signIn.response.status, 400, String(cookie));
            assert.include(signIn.html, "started in another browser");
            const consent = yield* getConsent(handler, mine.request, cookie);
            assert.strictEqual(consent.response.status, 400);
          }
          // The CSRF token must be this request's, from this browser's cookie.
          for (const csrf of ["", theirs.csrf, "forged"]) {
            const signIn = yield* post(
              handler,
              "/oauth/authorize/sign-in",
              { ...fields, csrf },
              mine.cookie,
            );
            assert.strictEqual(signIn.response.status, 400, csrf);
          }

          // Signed in, the decision is just as bound.
          const signedInMine = yield* signedIn(handler, query(clientId).search);
          for (const cookie of [null, theirs.cookie]) {
            const allowed = yield* decide(
              handler,
              { cookie: cookie ?? "", binding: signedInMine.binding },
              "allow",
            );
            assert.strictEqual(allowed.status, 400);
          }
          const forged = yield* post(
            handler,
            "/oauth/authorize/decision",
            { request: signedInMine.binding.request, csrf: theirs.csrf, decision: "allow" },
            signedInMine.cookie,
          );
          assert.strictEqual(forged.response.status, 400);
          // The real one still works.
          assert.strictEqual((yield* decide(handler, signedInMine, "allow")).status, 303);
        }),
      preview,
    ),
  );

  it.live("tells the agent when the user cancels, and answers each request once", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const started = yield* signedIn(handler, query(clientId).search);
          const cancelled = yield* decide(handler, started, "cancel");
          assert.strictEqual(cancelled.status, 303);
          const back = location(cancelled);
          assert.strictEqual(back.searchParams.get("error"), "access_denied");
          assert.strictEqual(back.searchParams.get("state"), "state-1");
          assert.strictEqual(back.searchParams.get("iss"), origin);
          assert.isNull(back.searchParams.get("code"));
          assert.strictEqual((yield* decide(handler, started, "allow")).status, 400);

          // Cancel works before signing in too.
          const fresh = yield* start(handler, query(clientId).search);
          const early = yield* decide(
            handler,
            { cookie: fresh.cookie, binding: binding(fresh.html) },
            "cancel",
          );
          assert.strictEqual(location(early).searchParams.get("error"), "access_denied");

          // Once allowed, it can't be cancelled, and every connection asks again.
          const again = yield* signedIn(handler, query(clientId).search);
          assert.strictEqual((yield* decide(handler, again, "allow")).status, 303);
          assert.strictEqual((yield* decide(handler, again, "cancel")).status, 400);
          const next = yield* start(handler, query(clientId).search);
          assert.include(next.html, "Sign in to a Test Account");

          // Allowing needs someone signed in.
          const unsigned = yield* start(handler, query(clientId).search);
          const allowed = yield* decide(
            handler,
            { cookie: unsigned.cookie, binding: binding(unsigned.html) },
            "allow",
          );
          assert.strictEqual(allowed.status, 400);
        }),
      preview,
    ),
  );

  it.live("sends the same code again when Allow is sent twice, until it's used", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const { search, verifier } = query(clientId);
          const started = yield* signedIn(handler, search);
          // A double click: both arrive before either answer.
          const [first, second] = yield* Effect.all(
            [decide(handler, started, "allow"), decide(handler, started, "allow")],
            { concurrency: "unbounded" },
          );
          assert.strictEqual(first.status, 303);
          assert.strictEqual(second.status, 303);
          const code = location(first).searchParams.get("code") ?? "";
          assert.strictEqual(location(second).searchParams.get("code"), code);
          assert.strictEqual((yield* exchangeCode(handler, clientId, code, verifier)).status, 200);
          // Used, it's never sent again.
          assert.strictEqual((yield* decide(handler, started, "allow")).status, 400);
        }),
      preview,
    ),
  );

  it.live("lets one browser have two requests going at once", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const first = yield* signedIn(handler, query(clientId).search);
          const second = yield* signedIn(handler, query(clientId).search);
          // The browser sends both cookies with each request.
          const both = `${first.cookie}; ${second.cookie}`;
          for (const started of [second, first]) {
            const allowed = yield* decide(
              handler,
              { cookie: both, binding: started.binding },
              "allow",
            );
            assert.strictEqual(allowed.status, 303);
            // Only its own cookie expires.
            const expired = allowed.headers.get("set-cookie") ?? "";
            assert.isTrue(expired.startsWith(`${started.cookie.split("=")[0]}=;`), expired);
          }
        }),
      preview,
    ),
  );

  it.live("names who's asking: unverified for a registered client, by domain for a CIMD one", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const named = yield* registerClient(handler, `<script>alert("hi")</script>`);
          const page = yield* start(handler, query(named).search);
          assert.notInclude(page.html, "<script>");
          assert.include(page.html, escape(`<script>alert("hi")</script>`));
          assert.include(page.html, "Unverified");

          const claudeCode = yield* storeClaudeCode;
          const cimd = yield* start(
            handler,
            query(claudeCode, { redirect_uri: "http://localhost:4123/callback" }).search,
          );
          assert.strictEqual(cimd.response.status, 200);
          assert.include(cimd.html, "Sign in to connect Claude Code to lil health");
          assert.include(cimd.html, "Identified by <strong>claude.ai</strong>");
          assert.notInclude(cimd.html, "Unverified");
          assert.include(cimd.html, "a program on this computer");
        }),
      preview,
    ),
  );

  it.live("has no sign-in in staging yet, on the issuer's host only", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const issuer = "https://api.staging.lil.tech";
          const registered = yield* Effect.promise(async () => {
            const response = await handler(
              new Request(`${issuer}/oauth/register`, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ redirect_uris: [redirectUri] }),
              }),
            );
            return (await response.json()) as { client_id: string };
          });
          const { search } = query(registered.client_id, { resource: undefined });
          const started = yield* start(handler, search, issuer);
          assert.strictEqual(started.response.status, 200);
          assert.include(started.html, "isn't available here yet");
          assert.notInclude(started.html, "Sign in to a Test Account");
          const signIn = yield* post(
            handler,
            "/oauth/authorize/sign-in",
            { request: started.request, csrf: started.csrf, account: "e2e" },
            started.cookie,
            issuer,
          );
          assert.strictEqual(signIn.response.status, 404);
          // Staging's resource is its MCP host's.
          const [row] = yield* (yield* CoreDb)
            .select({ resource: agentAuthorizations.resource })
            .from(agentAuthorizations)
            .where(eq(agentAuthorizations.id, started.request as never));
          assert.strictEqual(row?.resource, "https://mcp.staging.lil.tech/health");
          const onMcp = yield* fetchWith(
            handler,
            new Request(`https://mcp.staging.lil.tech/oauth/authorize?${search}`),
          );
          assert.strictEqual(onMcp.response.status, 404);
        }).pipe(Effect.orDie),
      staging,
    ),
  );

  it.live("counts starting and signing in against the sign-in limit, per IP address", () => {
    let count = 0;
    const allowed: RateLimitCounter = () => Effect.succeed(true);
    const limits = RateLimits.make({
      signIn: () => Effect.sync(() => ++count <= 3),
      user: allowed,
      refresh: allowed,
      clientRegistration: allowed,
      agentToken: allowed,
    });
    return withApi(
      (handler) =>
        Effect.gen(function* () {
          const clientId = yield* registerClient(handler);
          const from = { "cf-connecting-ip": "192.0.2.1" };
          const request = () =>
            new Request(`${origin}/oauth/authorize?${query(clientId).search}`, { headers: from });
          const started = yield* fetchWith(handler, request());
          const fields = { ...binding(started.html), account: "e2e" };
          const cookie = /^[^;]+/.exec(started.response.headers.get("set-cookie") ?? "")?.[0] ?? "";
          const signIn = () =>
            fetchWith(
              handler,
              new Request(`${origin}/oauth/authorize/sign-in`, {
                method: "POST",
                headers: {
                  ...from,
                  "content-type": "application/x-www-form-urlencoded",
                  cookie,
                },
                body: new URLSearchParams(fields).toString(),
              }),
            );
          assert.strictEqual((yield* signIn()).response.status, 303);
          assert.strictEqual((yield* fetchWith(handler, request())).response.status, 200);
          const limited = yield* signIn();
          assert.strictEqual(limited.response.status, 429);
          assert.strictEqual(limited.response.headers.get("retry-after"), "60");
          assert.strictEqual((yield* fetchWith(handler, request())).response.status, 429);
        }),
      preview,
      limits,
    );
  });

  it.live("isn't in prod yet", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const { response } = yield* fetchWith(
            handler,
            new Request(`https://api.lil.tech/oauth/authorize?${query("cli_x").search}`),
          );
          assert.strictEqual(response.status, 404);
        }),
      prod,
    ),
  );
});

describe("The authorization page's helpers", () => {
  it("lets forms redirect to the agent's origin, or its private-use scheme", () => {
    assert.strictEqual(
      formActionSource("http://localhost:4123/callback?x=1"),
      "http://localhost:4123",
    );
    assert.strictEqual(
      formActionSource("https://claude.ai/api/mcp/auth_callback"),
      "https://claude.ai",
    );
    assert.strictEqual(formActionSource("com.example.app:/oauth"), "com.example.app:");
  });

  it("reads the whole query, which may hold another ?", () => {
    assert.strictEqual(queryOf("/oauth/authorize?state=a?b&client_id=x"), "state=a?b&client_id=x");
    assert.strictEqual(queryOf("/oauth/authorize"), "");
  });

  it("escapes everything a client supplies", () => {
    assert.strictEqual(
      escape(`<a href="x">'&'</a>`),
      "&#60;a href=&#34;x&#34;&#62;&#39;&#38;&#39;&#60;/a&#62;",
    );
  });
});
