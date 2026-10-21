import { assert, describe, it } from "@effect/vitest";
import { Effect, Exit, Fiber, Option } from "effect";
import { TestClock } from "effect/testing";
import { OAuthClients, unusedClientAge } from "../../src/core/OAuthClients.ts";
import type { Deployment } from "../../src/Deployment.ts";
import {
  ClientMetadataFetch,
  clientMetadataAge,
  InvalidClient,
} from "../../src/oauth/ClientMetadata.ts";
import { agentHosts, resourceUrl } from "../../src/oauth/Hosts.ts";
import { matchesRedirectUri, redirectUriProblem } from "../../src/oauth/RedirectUris.ts";
import { type RateLimitName, RateLimits } from "../../src/RateLimits.ts";
import { TestCore } from "../core/TestCoreDatabase.ts";
import { type Handler, send, withApi } from "../TestApi.ts";

const preview: Deployment["Service"] = { environment: "preview", version: "1" };
const staging: Deployment["Service"] = { environment: "staging", version: "1" };
const prod: Deployment["Service"] = { environment: "prod", version: "1" };

/** A preview's one host, on workers.dev. */
const previewOrigin = "https://lil-api-pr-12.example.workers.dev";

const get = (handler: Handler, url: string, headers: Record<string, string> = {}) =>
  Effect.promise(() => handler(new Request(url, { headers })));

const json = (response: Response) => Effect.promise(() => response.json() as Promise<unknown>);

const register = (handler: Handler, body: unknown, headers: Record<string, string> = {}) =>
  send(
    handler,
    new Request(`${previewOrigin}/oauth/register`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: typeof body === "string" ? body : JSON.stringify(body),
    }),
  );

describe("OAuth metadata", () => {
  it.live("serves both documents on a preview's one host, naming that host", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const server = yield* get(
            handler,
            `${previewOrigin}/.well-known/oauth-authorization-server`,
          );
          assert.strictEqual(server.status, 200);
          assert.deepStrictEqual(yield* json(server), {
            issuer: previewOrigin,
            authorization_endpoint: `${previewOrigin}/oauth/authorize`,
            token_endpoint: `${previewOrigin}/oauth/token`,
            registration_endpoint: `${previewOrigin}/oauth/register`,
            revocation_endpoint: `${previewOrigin}/oauth/revoke`,
            response_types_supported: ["code"],
            grant_types_supported: ["authorization_code", "refresh_token"],
            code_challenge_methods_supported: ["S256"],
            token_endpoint_auth_methods_supported: ["none"],
            revocation_endpoint_auth_methods_supported: ["none"],
            client_id_metadata_document_supported: true,
            authorization_response_iss_parameter_supported: true,
            scopes_supported: ["health:read"],
          });
          const resource = yield* get(
            handler,
            `${previewOrigin}/.well-known/oauth-protected-resource/health`,
          );
          assert.strictEqual(resource.status, 200);
          assert.deepStrictEqual(yield* json(resource), {
            resource: `${previewOrigin}/health`,
            authorization_servers: [previewOrigin],
            scopes_supported: ["health:read"],
            bearer_methods_supported: ["header"],
            resource_name: "lil health",
            resource_documentation: "https://lil.tech/agents",
          });
          // The root is left for a combined server later, and there's no OpenID discovery.
          for (const path of [
            "/.well-known/oauth-protected-resource",
            "/.well-known/openid-configuration",
          ]) {
            assert.strictEqual((yield* get(handler, `${previewOrigin}${path}`)).status, 404, path);
          }
        }),
      preview,
    ),
  );

  it.live("lets any web origin read them, without credentials", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const origin = { origin: "http://localhost:6274" };
          for (const path of [
            "/.well-known/oauth-authorization-server",
            "/.well-known/oauth-protected-resource/health",
          ]) {
            const response = yield* get(handler, `${previewOrigin}${path}`, origin);
            assert.strictEqual(response.headers.get("access-control-allow-origin"), "*", path);
            assert.isNull(response.headers.get("access-control-allow-credentials"), path);
            const preflight = yield* Effect.promise(() =>
              handler(
                new Request(`${previewOrigin}${path}`, {
                  method: "OPTIONS",
                  headers: {
                    ...origin,
                    "access-control-request-method": "GET",
                    "access-control-request-headers": "mcp-protocol-version",
                  },
                }),
              ),
            );
            assert.strictEqual(preflight.status, 204, path);
            assert.strictEqual(preflight.headers.get("access-control-allow-origin"), "*");
            assert.strictEqual(preflight.headers.get("access-control-allow-methods"), "GET");
            assert.strictEqual(
              preflight.headers.get("access-control-allow-headers"),
              "mcp-protocol-version",
            );
          }
          // The apps' API gets no CORS.
          const status = yield* get(handler, `${previewOrigin}/v1/status`, origin);
          assert.isNull(status.headers.get("access-control-allow-origin"));
        }),
      preview,
    ),
  );

  it.live("keeps the authorization server and the MCP servers on their own hosts", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const resource = yield* get(
            handler,
            "https://mcp.staging.lil.tech/.well-known/oauth-protected-resource/health",
          );
          assert.strictEqual(resource.status, 200);
          assert.deepInclude(yield* json(resource), {
            resource: "https://mcp.staging.lil.tech/health",
            authorization_servers: ["https://api.staging.lil.tech"],
            resource_documentation: "https://staging.lil.tech/agents",
          });
          const server = yield* get(
            handler,
            "https://api.staging.lil.tech/.well-known/oauth-authorization-server",
          );
          assert.strictEqual(server.status, 200);
          assert.deepInclude(yield* json(server), {
            issuer: "https://api.staging.lil.tech",
            registration_endpoint: "https://api.staging.lil.tech/oauth/register",
          });
          // Neither host serves the other's routes.
          for (const url of [
            "https://api.staging.lil.tech/.well-known/oauth-protected-resource/health",
            "https://mcp.staging.lil.tech/.well-known/oauth-authorization-server",
            "https://mcp.staging.lil.tech/v1/status",
            "https://mcp.staging.lil.tech/oauth/register",
            // The Worker's workers.dev URL isn't the issuer, so it has no authorization server.
            "https://lil-api-staging.example.workers.dev/.well-known/oauth-authorization-server",
          ]) {
            assert.strictEqual((yield* get(handler, url)).status, 404, url);
          }
          assert.strictEqual(
            (yield* get(handler, "https://api.staging.lil.tech/v1/status")).status,
            200,
          );
        }),
      staging,
    ),
  );

  it("takes prod's hosts from its config, whichever host is asked", () => {
    const hosts = agentHosts("prod", "https://mcp.lil.tech");
    assert.deepStrictEqual(hosts, {
      issuer: "https://api.lil.tech",
      mcp: "https://mcp.lil.tech",
      shared: false,
    });
    assert.strictEqual(resourceUrl(hosts, "health"), "https://mcp.lil.tech/health");
    assert.strictEqual(
      resourceUrl(agentHosts("preview", previewOrigin), "health"),
      `${previewOrigin}/health`,
    );
  });

  it.live("serves prod's documents on its own hosts, since the launch", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const resource = yield* get(
            handler,
            "https://mcp.lil.tech/.well-known/oauth-protected-resource/health",
          );
          assert.strictEqual(resource.status, 200);
          assert.deepInclude(yield* json(resource), {
            resource: "https://mcp.lil.tech/health",
            authorization_servers: ["https://api.lil.tech"],
            resource_documentation: "https://lil.tech/agents",
          });
          const server = yield* get(
            handler,
            "https://api.lil.tech/.well-known/oauth-authorization-server",
          );
          assert.strictEqual(server.status, 200);
          assert.deepInclude(yield* json(server), {
            issuer: "https://api.lil.tech",
            authorization_endpoint: "https://api.lil.tech/oauth/authorize",
          });
          for (const url of [
            "https://api.lil.tech/.well-known/oauth-protected-resource/health",
            "https://mcp.lil.tech/.well-known/oauth-authorization-server",
            "https://mcp.lil.tech/v1/status",
          ]) {
            assert.strictEqual((yield* get(handler, url)).status, 404, url);
          }
          assert.strictEqual((yield* get(handler, "https://api.lil.tech/v1/status")).status, 200);
        }),
      prod,
    ),
  );
});

describe("POST /oauth/register", () => {
  /** What MCP Inspector registers. */
  const inspector = {
    redirect_uris: ["http://localhost:6274/oauth/callback"],
    token_endpoint_auth_method: "none",
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    client_name: "MCP Inspector",
    client_uri: "https://github.com/modelcontextprotocol/inspector",
    logo_uri: "https://example.com/logo.png",
  };

  it.live("registers a public client, which then resolves with its redirect URIs", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const response = yield* register(handler, inspector);
          assert.strictEqual(response.status, 201);
          const body = response.body as Record<string, unknown>;
          assert.match(String(body["client_id"]), /^cli_[0-9a-z]{26}$/);
          assert.isNumber(body["client_id_issued_at"]);
          assert.notProperty(body, "client_secret");
          assert.notProperty(body, "logo_uri");
          assert.deepInclude(body, {
            client_name: "MCP Inspector",
            client_uri: "https://github.com/modelcontextprotocol/inspector",
            redirect_uris: ["http://localhost:6274/oauth/callback"],
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "none",
            application_type: "native",
          });
          const client = yield* (yield* OAuthClients).resolve(String(body["client_id"]));
          assert.deepInclude(client, {
            kind: "dcr",
            name: "MCP Inspector",
            redirectUris: ["http://localhost:6274/oauth/callback"],
          });
          // The fewest fields: no name, and the defaults.
          // Every client may refresh, even one that asked only for codes.
          const bare = yield* register(handler, {
            redirect_uris: ["https://example.com/cb"],
            grant_types: ["authorization_code"],
          });
          assert.strictEqual(bare.status, 201);
          assert.notProperty(bare.body, "client_name");
          assert.deepInclude(bare.body, {
            grant_types: ["authorization_code", "refresh_token"],
            token_endpoint_auth_method: "none",
            application_type: "web",
          });
        }),
      preview,
    ),
  );

  it.live("refuses what isn't a public code-flow client, with RFC 7591's errors", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const refused = (body: unknown, error: string) =>
            Effect.gen(function* () {
              const response = yield* register(handler, body);
              assert.strictEqual(response.status, 400, JSON.stringify(body).slice(0, 200));
              assert.propertyVal(response.body, "error", error);
              assert.isString((response.body as { error_description?: unknown }).error_description);
            });
          const uris = ["https://example.com/cb"];
          yield* refused(
            { ...inspector, token_endpoint_auth_method: "client_secret_basic" },
            "invalid_client_metadata",
          );
          yield* refused(
            { redirect_uris: uris, grant_types: ["client_credentials"] },
            "invalid_client_metadata",
          );
          yield* refused(
            { redirect_uris: uris, grant_types: ["refresh_token"] },
            "invalid_client_metadata",
          );
          yield* refused(
            { redirect_uris: uris, response_types: ["token"] },
            "invalid_client_metadata",
          );
          yield* refused(
            { redirect_uris: uris, client_name: "x".repeat(101) },
            "invalid_client_metadata",
          );
          yield* refused(
            { redirect_uris: uris, client_uri: "http://example.com" },
            "invalid_client_metadata",
          );
          yield* refused(
            { redirect_uris: uris, application_type: "service" },
            "invalid_client_metadata",
          );
          yield* refused({ client_name: "No redirects" }, "invalid_client_metadata");
          yield* refused("not json", "invalid_client_metadata");
          yield* refused([uris], "invalid_client_metadata");
          yield* refused({ redirect_uris: [] }, "invalid_redirect_uri");
          yield* refused({ redirect_uris: ["http://example.com/cb"] }, "invalid_redirect_uri");
          yield* refused({ redirect_uris: ["javascript:alert(1)"] }, "invalid_redirect_uri");
          yield* refused({ redirect_uris: ["https://example.com/cb#x"] }, "invalid_redirect_uri");
          yield* refused(
            { redirect_uris: [`https://example.com/${"x".repeat(2000)}`] },
            "invalid_redirect_uri",
          );
          yield* refused(
            { redirect_uris: Array.from({ length: 11 }, (_, i) => `https://example.com/${i}`) },
            "invalid_redirect_uri",
          );
          // Ten is fine, and so are private-use schemes.
          const ten = yield* register(handler, {
            redirect_uris: [
              "com.example.app:/oauth",
              ...Array.from({ length: 9 }, (_, i) => `https://example.com/${i}`),
            ],
          });
          assert.strictEqual(ten.status, 201);
        }),
      preview,
    ),
  );

  it.live("refuses a body over 8 KB", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const big = { redirect_uris: ["https://example.com/cb"], padding: "x".repeat(9000) };
          const response = yield* register(handler, big);
          assert.strictEqual(response.status, 413);
          assert.propertyVal(response.body, "error", "invalid_client_metadata");
          // Without a length, it stops reading at the limit.
          let sent = 0;
          const chunked = yield* send(
            handler,
            new Request(`${previewOrigin}/oauth/register`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: new ReadableStream<Uint8Array>({
                pull(controller) {
                  sent += 1024;
                  controller.enqueue(new Uint8Array(1024).fill(32));
                },
              }),
              duplex: "half",
            } as RequestInit),
          );
          assert.strictEqual(chunked.status, 413);
          assert.isBelow(sent, 64 * 1024);
        }),
      preview,
    ),
  );

  it.live("lets any web origin register, without credentials", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const origin = "http://localhost:6274";
          const preflight = yield* Effect.promise(() =>
            handler(
              new Request(`${previewOrigin}/oauth/register`, {
                method: "OPTIONS",
                headers: {
                  origin,
                  "access-control-request-method": "POST",
                  "access-control-request-headers": "content-type",
                },
              }),
            ),
          );
          assert.strictEqual(preflight.status, 204);
          assert.strictEqual(preflight.headers.get("access-control-allow-origin"), "*");
          assert.strictEqual(preflight.headers.get("access-control-allow-methods"), "POST");
          const response = yield* Effect.promise(() =>
            handler(
              new Request(`${previewOrigin}/oauth/register`, {
                method: "POST",
                headers: { origin, "content-type": "application/json" },
                body: JSON.stringify(inspector),
              }),
            ),
          );
          assert.strictEqual(response.status, 201);
          assert.strictEqual(response.headers.get("access-control-allow-origin"), "*");
          assert.isNull(response.headers.get("access-control-allow-credentials"));
          // So a rate-limited client can see when to try again.
          assert.strictEqual(response.headers.get("access-control-expose-headers"), "retry-after");
        }),
      preview,
    ),
  );

  it.live("limits registrations per IP address", () => {
    const counts = new Map<string, number>();
    const counter = (limit: RateLimitName, max: number) => (key: string) =>
      Effect.sync(() => {
        const count = (counts.get(`${limit}/${key}`) ?? 0) + 1;
        counts.set(`${limit}/${key}`, count);
        return count <= max;
      });
    const limits = RateLimits.make({
      signIn: counter("signIn", Infinity),
      user: counter("user", Infinity),
      refresh: counter("refresh", Infinity),
      clientRegistration: counter("clientRegistration", 1),
      agentToken: counter("agentToken", Infinity),
      agent: counter("agent", Infinity),
    });
    const body = { redirect_uris: ["https://example.com/cb"] };
    return withApi(
      (handler) =>
        Effect.gen(function* () {
          const from = (address: string) => ({ "cf-connecting-ip": address });
          assert.strictEqual((yield* register(handler, body, from("192.0.2.1"))).status, 201);
          const limited = yield* register(handler, body, from("192.0.2.1"));
          assert.deepStrictEqual(limited, {
            status: 429,
            body: { _tag: "TooManyRequests", retryAfterSeconds: 60 },
          });
          assert.strictEqual((yield* register(handler, body, from("192.0.2.2"))).status, 201);
        }),
      preview,
      limits,
    );
  });
});

describe("Client ID Metadata Documents", () => {
  const claudeCode = "https://claude.ai/oauth/claude-code-client-metadata";
  /** Claude Code's document, as claude.ai serves it. */
  const claudeCodeDocument = {
    client_id: claudeCode,
    client_name: "Claude Code",
    client_uri: "https://claude.ai",
    redirect_uris: ["http://localhost/callback", "http://127.0.0.1/callback"],
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
  };

  /** A fetch that answers every URL with `respond`'s response, counting the calls. */
  const fakeFetch = (respond: (url: string, init: RequestInit) => Response | Promise<Response>) => {
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetch = async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return respond(url, init);
    };
    return { calls, fetch };
  };

  const document = (body: unknown, headers: Record<string, string> = {}) =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      headers: { "content-type": "application/json", ...headers },
    });

  const resolveWith = (fetch: (url: string, init: RequestInit) => Promise<Response>, id: string) =>
    OAuthClients.use((clients) => clients.resolve(id)).pipe(
      Effect.provideService(ClientMetadataFetch, fetch),
    );

  /** Resolving `id` fails with `error`. */
  const refused = (
    fetch: (url: string, init: RequestInit) => Promise<Response>,
    id: string,
    error: InvalidClient["error"],
  ) =>
    Effect.gen(function* () {
      const failure = yield* Effect.flip(resolveWith(fetch, id));
      assert.instanceOf(failure, InvalidClient);
      assert.strictEqual(
        (failure as InvalidClient).error,
        error,
        (failure as InvalidClient).description,
      );
    });

  it.effect("resolves Claude Code's document, and caches it as it says", () =>
    Effect.gen(function* () {
      const { calls, fetch } = fakeFetch(() =>
        document(claudeCodeDocument, { "cache-control": "public, max-age=300" }),
      );
      const client = yield* resolveWith(fetch, claudeCode);
      assert.deepInclude(client, {
        clientId: claudeCode,
        kind: "cimd",
        name: "Claude Code",
        clientUri: "https://claude.ai",
        redirectUris: ["http://localhost/callback", "http://127.0.0.1/callback"],
        applicationType: "native",
      });
      assert.strictEqual(calls.length, 1);
      assert.strictEqual(calls[0]?.init.redirect, "manual");
      // Within its 5 minutes, from the cache.
      yield* TestClock.adjust("4 minutes");
      assert.strictEqual((yield* resolveWith(fetch, claudeCode)).id, client.id);
      assert.strictEqual(calls.length, 1);
      // Then fetched again, into the same row.
      yield* TestClock.adjust("2 minutes");
      assert.strictEqual((yield* resolveWith(fetch, claudeCode)).id, client.id);
      assert.strictEqual(calls.length, 2);
    }).pipe(Effect.provide(TestCore)),
  );

  it.effect("refuses documents that aren't the client's, or acceptable", () =>
    Effect.gen(function* () {
      const answer = (body: unknown) => fakeFetch(() => document(body)).fetch;
      yield* refused(
        answer({ ...claudeCodeDocument, client_id: "https://evil.example/meta" }),
        claudeCode,
        "invalid_client_metadata",
      );
      yield* refused(answer("<html>"), claudeCode, "invalid_client_metadata");
      yield* refused(answer([claudeCodeDocument]), claudeCode, "invalid_client_metadata");
      const { client_name: _, ...unnamed } = claudeCodeDocument;
      yield* refused(answer(unnamed), claudeCode, "invalid_client_metadata");
      yield* refused(
        answer({ ...claudeCodeDocument, token_endpoint_auth_method: "private_key_jwt" }),
        claudeCode,
        "invalid_client_metadata",
      );
      yield* refused(
        answer({ ...claudeCodeDocument, grant_types: ["client_credentials"] }),
        claudeCode,
        "invalid_client_metadata",
      );
      yield* refused(
        answer({ ...claudeCodeDocument, response_types: ["token"] }),
        claudeCode,
        "invalid_client_metadata",
      );
      yield* refused(
        answer({ ...claudeCodeDocument, redirect_uris: ["http://example.com/callback"] }),
        claudeCode,
        "invalid_redirect_uri",
      );
    }).pipe(Effect.provide(TestCore)),
  );

  it.effect("follows no redirects, and reads at most 16 KB", () =>
    Effect.gen(function* () {
      const redirect = fakeFetch(
        () => new Response(null, { status: 302, headers: { location: "http://10.0.0.1/" } }),
      );
      yield* refused(redirect.fetch, claudeCode, "invalid_client");
      const missing = fakeFetch(() => new Response("Not found", { status: 404 }));
      yield* refused(missing.fetch, claudeCode, "invalid_client");
      const padded = { ...claudeCodeDocument, padding: "x".repeat(17 * 1024) };
      yield* refused(fakeFetch(() => document(padded)).fetch, claudeCode, "invalid_client");
      // Without a length, it stops reading at the limit.
      const streamed = fakeFetch(
        () =>
          new Response(
            new ReadableStream({
              start(controller) {
                controller.enqueue(new TextEncoder().encode(JSON.stringify(padded)));
                controller.close();
              },
            }),
          ),
      );
      yield* refused(streamed.fetch, claudeCode, "invalid_client");
      const failing = fakeFetch(() => Promise.reject(new TypeError("Network connection lost")));
      yield* refused(failing.fetch, claudeCode, "invalid_client");
    }).pipe(Effect.provide(TestCore)),
  );

  it.effect("gives up on a fetch after 5 seconds", () =>
    Effect.gen(function* () {
      const signals: Array<AbortSignal> = [];
      const hanging = fakeFetch((_, init) => {
        if (init.signal) signals.push(init.signal);
        return new Promise<Response>(() => {});
      });
      const fiber = yield* resolveWith(hanging.fetch, claudeCode).pipe(
        Effect.flip,
        Effect.forkChild,
      );
      yield* TestClock.adjust("5 seconds");
      const failure = yield* Fiber.join(fiber);
      assert.propertyVal(failure, "error", "invalid_client");
      assert.isTrue(signals[0]?.aborted);
    }).pipe(Effect.provide(TestCore)),
  );

  it.effect("only fetches public HTTPS URLs with a path, never ours", () =>
    Effect.gen(function* () {
      const { calls, fetch } = fakeFetch(() => document(claudeCodeDocument));
      for (const id of [
        "http://claude.ai/oauth/claude-code-client-metadata",
        "https://claude.ai",
        "https://claude.ai/",
        "https://claude.ai/meta#x",
        "https://user:pass@claude.ai/meta",
        "https://claude.ai/a/../meta",
        "https://CLAUDE.ai/meta",
        "https://claude.ai:443/meta",
        "https://127.0.0.1/meta",
        "https://[::1]/meta",
        "https://0x7f000001/meta",
        "https://lil.tech/meta",
        "https://api.lil.tech/meta",
        "https://api.lil.tech./meta",
        `https://claude.ai/${"x".repeat(2000)}`,
      ]) {
        yield* refused(fetch, id, "invalid_client");
      }
      assert.strictEqual(calls.length, 0);
      // An ID that's neither a URL nor registered.
      yield* refused(fetch, "cli_00000000000000000000000000", "invalid_client");
      yield* refused(fetch, "some-client", "invalid_client");
    }).pipe(Effect.provide(TestCore)),
  );

  it("caches documents between 5 minutes and a day", () => {
    const minutes = (ms: number) => ms / 60_000;
    assert.strictEqual(minutes(clientMetadataAge("public, max-age=300")), 5);
    assert.strictEqual(minutes(clientMetadataAge("max-age=3600")), 60);
    assert.strictEqual(minutes(clientMetadataAge("max-age=10")), 5);
    assert.strictEqual(minutes(clientMetadataAge("max-age=604800")), 24 * 60);
    assert.strictEqual(minutes(clientMetadataAge("no-store")), 5);
    assert.strictEqual(minutes(clientMetadataAge("max-age=3600, no-cache")), 5);
    assert.strictEqual(minutes(clientMetadataAge(null)), 5);
  });
});

describe("redirect URIs", () => {
  it("allows HTTPS, loopback http and private-use schemes", () => {
    for (const uri of [
      "https://claude.ai/api/mcp/auth_callback",
      "https://chatgpt.com/connector/oauth/abc",
      "http://localhost/callback",
      "http://127.0.0.1:33418/callback",
      "http://[::1]:8080/cb",
      "com.example.app:/oauth2redirect",
      "tech.lil.health://callback",
    ]) {
      assert.isTrue(Option.isNone(redirectUriProblem(uri)), uri);
    }
    for (const uri of [
      "http://example.com/callback",
      "http://localhost.example.com/callback",
      "https://example.com/cb#fragment",
      "https://user@example.com/cb",
      "javascript:alert(1)",
      "data:text/html,hi",
      "file:///etc/passwd",
      "myapp://callback",
      "not a url",
      `https://example.com/${"x".repeat(2000)}`,
    ]) {
      assert.isTrue(Option.isSome(redirectUriProblem(uri)), uri);
    }
  });

  it("matches exactly, but ignores a loopback URI's port", () => {
    const registered = ["http://localhost/callback", "http://127.0.0.1/callback"];
    assert.isTrue(matchesRedirectUri(registered, "http://localhost/callback"));
    assert.isTrue(matchesRedirectUri(registered, "http://localhost:53712/callback"));
    assert.isTrue(matchesRedirectUri(registered, "http://127.0.0.1:33418/callback"));
    assert.isFalse(matchesRedirectUri(registered, "http://localhost:53712/other"));
    assert.isFalse(matchesRedirectUri(registered, "http://localhost:53712/callback?x=1"));
    assert.isFalse(matchesRedirectUri(registered, "http://[::1]:53712/callback"));
    assert.isFalse(matchesRedirectUri(registered, "https://localhost:53712/callback"));
    const web = ["https://claude.ai/api/mcp/auth_callback"];
    assert.isTrue(matchesRedirectUri(web, "https://claude.ai/api/mcp/auth_callback"));
    assert.isFalse(matchesRedirectUri(web, "https://claude.ai:8443/api/mcp/auth_callback"));
    assert.isFalse(matchesRedirectUri(web, "https://claude.ai/api/mcp/auth_callback/"));
    assert.isFalse(matchesRedirectUri(web, "https://claude.ai/api/mcp/auth_callback?x=1"));
  });
});

describe("OAuthClients.deleteUnused", () => {
  const day = 24 * 60 * 60 * 1000;
  const metadata = {
    name: "Inspector",
    clientUri: null,
    redirectUris: ["http://localhost:6274/oauth/callback"],
    applicationType: "native" as const,
  };

  it.effect("deletes registrations a day after their last use, and others after 90 days", () =>
    Effect.gen(function* () {
      const clients = yield* OAuthClients;
      const unused = yield* clients.register(metadata);
      const used = yield* clients.register(metadata);
      yield* clients.resolve(used.clientId);
      const cimd = "https://claude.ai/oauth/claude-code-client-metadata";
      yield* clients.resolve(cimd).pipe(
        Effect.provideService(ClientMetadataFetch, async () =>
          Response.json({
            client_id: cimd,
            client_name: "Claude Code",
            redirect_uris: ["http://localhost/callback"],
          }),
        ),
      );

      // Neither registration got a grant (the grants' tests cover clients that do).
      yield* TestClock.adjust(day - 1);
      assert.strictEqual(yield* clients.deleteUnused, 0);
      yield* TestClock.adjust(2);
      assert.strictEqual(yield* clients.deleteUnused, 2);
      assert.isTrue(Exit.isFailure(yield* clients.resolve(unused.clientId).pipe(Effect.exit)));

      // The document's cached copy lasts until 90 days after it was last used.
      yield* TestClock.adjust(unusedClientAge - day - 2);
      assert.strictEqual(yield* clients.deleteUnused, 0);
      yield* TestClock.adjust(2);
      assert.strictEqual(yield* clients.deleteUnused, 1);
    }).pipe(Effect.provide(TestCore)),
  );
});
