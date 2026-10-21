import { Effect, Option } from "effect";
import { HttpMiddleware, HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import type { SqlError } from "effect/sql";
import { OAuthClients } from "../core/OAuthClients.ts";
import { Deployment } from "../Deployment.ts";
import { checkAddressRateLimit, RateLimits, tooManyRequests } from "../RateLimits.ts";
import { type AgentTokenPair, AgentTokens, TokenRequestError } from "./AgentTokens.ts";
import { addAuthorizationPage } from "./AuthorizationPage.ts";
import { checkRegistration, InvalidClient, supportedGrantTypes } from "./ClientMetadata.ts";
import { InvalidForm, readAtMost, readForm, requestOrigin, requestPath } from "./Requests.ts";
import {
  type AgentHosts,
  AgentApps,
  agentAccessEnvironments,
  agentHosts,
  agentsHelpUrl,
  appMetadataPath,
  appUrl,
  authorizationServerMetadataPath,
  canonicalResource,
  combinedAgentEnvironments,
  combinedResourceMetadataPath,
  combinedResourceUrl,
  isAuthorizationServerPath,
  isMcpPath,
  scopesOf,
} from "./Hosts.ts";

// The agents' authorization server's endpoints: its metadata (RFC 8414), each app's Protected
// Resource Metadata (RFC 9728), dynamic client registration (RFC 7591) (851-2847), the token and
// revocation endpoints (RFC 6749, RFC 7009) (851-2848), and the authorization page
// (`AuthorizationPage.ts`, 851-2849), and the combined server's metadata at the MCP host's root
// (851-2899). They follow their own RFCs, so they're left out of the OpenAPI spec, like
// `/v1/auth/dev`.

/** The largest registration body `POST /oauth/register` reads. */
export const maxRegistrationBytes = 8 * 1024;

/** The largest form `POST /oauth/token` and `POST /oauth/revoke` read. */
export const maxTokenRequestBytes = 8 * 1024;

const notFound = HttpServerResponse.empty({ status: 404 });

/**
 * Keeps the API and the MCP servers on their own hosts in prod and staging: the MCP host
 * (`mcp.lil.tech`) serves only the MCP servers and their metadata, other hosts never serve those,
 * and the authorization server is only on its issuer's host (so not on the Worker's workers.dev
 * URL, whose documents would name another issuer). Everything else 404s. On workers.dev, which has
 * one host, every route is on it.
 */
export const AgentHostsMiddleware = HttpRouter.middleware(
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    const registry = yield* AgentApps;
    return <E, R>(httpEffect: Effect.Effect<HttpServerResponse.HttpServerResponse, E, R>) =>
      HttpServerRequest.HttpServerRequest.use((request) => {
        const origin = requestOrigin(request);
        const hosts = agentHosts(environment, origin);
        if (hosts.shared) return httpEffect;
        const path = requestPath(request);
        const allowed =
          origin === hosts.mcp
            ? isMcpPath(path, registry)
            : !isMcpPath(path, registry) &&
              (origin === hosts.issuer || !isAuthorizationServerPath(path));
        return allowed ? httpEffect : Effect.succeed(notFound);
      });
  }),
  { global: true },
);

/**
 * Lets any origin call a route, without credentials, answering `OPTIONS` preflights. `Retry-After`
 * is readable, for a rate-limited registration.
 */
const cors = (method: "GET" | "POST") =>
  HttpMiddleware.cors({
    allowedMethods: [method],
    exposedHeaders: ["retry-after"],
    maxAge: 24 * 60 * 60,
  });

/** Adds a route that any web origin may call (and its preflight), as browser-based clients do. */
const addPublic = <E, R>(
  router: HttpRouter.HttpRouter,
  method: "GET" | "POST",
  path: `/${string}`,
  handler: Effect.Effect<HttpServerResponse.HttpServerResponse, E, R>,
) =>
  Effect.gen(function* () {
    yield* router.add(method, path, cors(method)(handler));
    yield* router.add("OPTIONS", path, cors(method)(handler));
  });

/** A metadata document, which clients may cache for a while. */
const document = (body: object) =>
  HttpServerResponse.jsonUnsafe(body, { headers: { "cache-control": "public, max-age=300" } });

/** An OAuth error response (RFC 6749 §5.2, RFC 7591 §3.2.2). */
const oauthError = (status: number, error: string, description: string) =>
  HttpServerResponse.jsonUnsafe(
    { error, error_description: description },
    { status, headers: { "cache-control": "no-store" } },
  );

/** A response to a token request, which mustn't be cached (RFC 6749 §5.1). */
const tokenResponse = (body: object) =>
  HttpServerResponse.jsonUnsafe(body, {
    headers: { "cache-control": "no-store", pragma: "no-cache" },
  });

/**
 * The token or revocation request's form (RFC 6749 §3.2), with `require` for its parameters that
 * must be there.
 */
const readTokenForm = Effect.map(readForm(maxTokenRequestBytes), (params) => ({
  get: (name: string) => Option.fromNullishOr(params.get(name)),
  require: (name: string) =>
    Option.match(Option.fromNullishOr(params.get(name)), {
      onNone: () =>
        Effect.fail(
          new TokenRequestError({ error: "invalid_request", description: `${name} is missing` }),
        ),
      onSome: Effect.succeed,
    }),
}));

/** Answers a token or revocation request's errors as RFC 6749 §5.2 does. Others are defects. */
const catchOAuthErrors = <R>(
  effect: Effect.Effect<
    HttpServerResponse.HttpServerResponse,
    InvalidForm | TokenRequestError | SqlError.SqlError,
    R
  >,
) =>
  effect.pipe(
    Effect.catchTags({
      InvalidForm: (error: InvalidForm) =>
        Effect.succeed(oauthError(400, "invalid_request", error.description)),
      TokenRequestError: (error: TokenRequestError) =>
        Effect.succeed(oauthError(400, error.error, error.description)),
    }),
    Effect.orDie,
  );

/**
 * `POST /oauth/token`: a code exchange or a refresh, for public clients (no authentication). The
 * combined server's URL with a trailing slash is the same resource as without one.
 */
const tokenEndpoint = (tokens: AgentTokens["Service"]) =>
  Effect.gen(function* () {
    const form = yield* readTokenForm;
    const grantType = yield* form.require("grant_type");
    const clientId = yield* form.require("client_id");
    const resource = Option.map(form.get("resource"), canonicalResource);
    if (grantType === "authorization_code") {
      return tokenResponse(
        pairBody(
          yield* tokens.exchangeCode({
            code: yield* form.require("code"),
            clientId,
            redirectUri: yield* form.require("redirect_uri"),
            codeVerifier: yield* form.require("code_verifier"),
            resource,
          }),
        ),
      );
    }
    if (grantType === "refresh_token") {
      return tokenResponse(
        pairBody(
          yield* tokens.refresh({
            refreshToken: yield* form.require("refresh_token"),
            clientId,
            resource,
            scope: form.get("scope"),
          }),
        ),
      );
    }
    return yield* new TokenRequestError({
      error: "unsupported_grant_type",
      description: "Only authorization_code and refresh_token are supported",
    });
  }).pipe(Effect.catchTag("TooManyRequests", tooManyRequests), catchOAuthErrors);

const pairBody = (pair: AgentTokenPair) => ({
  access_token: pair.accessToken,
  token_type: "Bearer",
  expires_in: pair.expiresIn,
  refresh_token: pair.refreshToken,
  scope: pair.scope,
});

/**
 * `POST /oauth/revoke` (RFC 7009): answers 200 whether or not the token was known, so it can't be
 * used to probe for tokens.
 */
const revocationEndpoint = (tokens: AgentTokens["Service"]) =>
  Effect.gen(function* () {
    const form = yield* readTokenForm;
    yield* tokens.revoke(yield* form.require("token"), form.get("client_id"));
    return HttpServerResponse.empty({ status: 200, headers: { "cache-control": "no-store" } });
  }).pipe(catchOAuthErrors);

/** The authorization server's metadata, on the API's host, listing every app's scopes. */
const authorizationServerMetadata = (issuer: string, scopes: ReadonlyArray<string>) => ({
  issuer,
  authorization_endpoint: `${issuer}/oauth/authorize`,
  token_endpoint: `${issuer}/oauth/token`,
  registration_endpoint: `${issuer}/oauth/register`,
  revocation_endpoint: `${issuer}/oauth/revoke`,
  response_types_supported: ["code"],
  grant_types_supported: ["authorization_code", "refresh_token"],
  code_challenge_methods_supported: ["S256"],
  token_endpoint_auth_methods_supported: ["none"],
  revocation_endpoint_auth_methods_supported: ["none"],
  // Claude only uses Client ID Metadata Documents when this is set, with `none` above.
  client_id_metadata_document_supported: true,
  authorization_response_iss_parameter_supported: true,
  scopes_supported: scopes,
});

/**
 * The agents' metadata documents, `POST /oauth/register`, `/oauth/token`, `/oauth/revoke` and the
 * authorization page (`/oauth/authorize`), only where agents may connect (`agentAccessEnvironments`);
 * elsewhere they're a 404.
 */
export const AgentOAuthRoutes = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    if (!agentAccessEnvironments.has(environment)) return;
    const clients = yield* OAuthClients;
    const tokens = yield* AgentTokens;
    const limits = yield* RateLimits;
    const apps = yield* AgentApps;
    const hostsOf = HttpServerRequest.HttpServerRequest.use((request) =>
      Effect.succeed(agentHosts(environment, requestOrigin(request))),
    );

    yield* addPublic(
      router,
      "GET",
      authorizationServerMetadataPath,
      Effect.map(hostsOf, (hosts) =>
        document(authorizationServerMetadata(hosts.issuer, scopesOf(apps))),
      ),
    );

    /** A protected resource's metadata (RFC 9728), naming the one authorization server. */
    const resourceMetadata = (
      path: string,
      resource: (hosts: AgentHosts) => string,
      name: string,
      scopes: ReadonlyArray<string>,
    ) =>
      addPublic(
        router,
        "GET",
        path as `/${string}`,
        Effect.map(hostsOf, (hosts) =>
          document({
            resource: resource(hosts),
            // The one authorization server for every app. Claude only reads the first.
            authorization_servers: [hosts.issuer],
            scopes_supported: scopes,
            bearer_methods_supported: ["header"],
            resource_name: name,
            resource_documentation: agentsHelpUrl(environment),
          }),
        ),
      );

    for (const app of Object.values(apps)) {
      yield* resourceMetadata(
        appMetadataPath(app),
        (hosts) => appUrl(hosts, app),
        app.name,
        app.scopes,
      );
    }
    // The combined server, every app's, at the root, where agents look first.
    if (combinedAgentEnvironments.has(environment)) {
      yield* resourceMetadata(
        combinedResourceMetadataPath,
        combinedResourceUrl,
        "lil",
        scopesOf(apps),
      );
    }

    yield* addPublic(
      router,
      "POST",
      "/oauth/register",
      Effect.gen(function* () {
        yield* checkAddressRateLimit(limits, "clientRegistration");
        const request = yield* HttpServerRequest.HttpServerRequest;
        const tooLarge = oauthError(
          413,
          "invalid_client_metadata",
          `The registration is larger than ${maxRegistrationBytes} bytes`,
        );
        if (Number(request.headers["content-length"] ?? 0) > maxRegistrationBytes) return tooLarge;
        const body = yield* readAtMost(request.stream, maxRegistrationBytes).pipe(
          Effect.mapError(
            () =>
              new InvalidClient({
                error: "invalid_client_metadata",
                description: "The registration couldn't be read",
              }),
          ),
        );
        if (Option.isNone(body)) return tooLarge;
        const metadata = yield* checkRegistration(body.value);
        const client = yield* clients.register(metadata).pipe(Effect.orDie);
        return HttpServerResponse.jsonUnsafe(
          {
            client_id: client.clientId,
            client_id_issued_at: Math.floor(client.createdAt / 1000),
            ...(client.name === null ? {} : { client_name: client.name }),
            ...(client.clientUri === null ? {} : { client_uri: client.clientUri }),
            redirect_uris: client.redirectUris,
            // Every client may refresh: RFC 7591 lets the server replace what was asked for.
            grant_types: supportedGrantTypes,
            response_types: ["code"],
            token_endpoint_auth_method: "none",
            application_type: client.applicationType,
          },
          { status: 201, headers: { "cache-control": "no-store" } },
        );
      }).pipe(
        Effect.catchTag("TooManyRequests", tooManyRequests),
        Effect.catchTag("InvalidClient", (error: InvalidClient) =>
          Effect.succeed(oauthError(400, error.error, error.description)),
        ),
      ),
    );

    yield* addPublic(router, "POST", "/oauth/token", tokenEndpoint(tokens));
    yield* addPublic(router, "POST", "/oauth/revoke", revocationEndpoint(tokens));

    // Not public: the page uses a cookie, so it has no CORS.
    yield* addAuthorizationPage(router, environment);
  }),
);
