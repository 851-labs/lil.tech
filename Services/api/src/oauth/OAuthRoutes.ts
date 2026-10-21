import { Effect } from "effect";
import { HttpMiddleware, HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { OAuthClients } from "../core/OAuthClients.ts";
import { Deployment } from "../Deployment.ts";
import { checkAddressRateLimit, RateLimits, tooManyRequests } from "../RateLimits.ts";
import { checkRegistration, InvalidClient } from "./ClientMetadata.ts";
import {
  agentAccessEnvironments,
  agentHosts,
  agentResources,
  agentScopes,
  agentsHelpUrl,
  authorizationServerMetadataPath,
  isMcpPath,
  protectedResourceMetadataPath,
  resourceUrl,
} from "./Hosts.ts";

// The agents' authorization server's public endpoints (851-2847): its metadata (RFC 8414), each
// app's Protected Resource Metadata (RFC 9728), and dynamic client registration (RFC 7591). They
// follow their own RFCs, so they're left out of the OpenAPI spec, like `/v1/auth/dev`.

/** The largest registration body `POST /oauth/register` reads. */
export const maxRegistrationBytes = 8 * 1024;

/** The request's origin, as the client used it. */
const requestOrigin = (request: HttpServerRequest.HttpServerRequest) => {
  try {
    return new URL(request.originalUrl).origin;
  } catch {
    return `https://${request.headers["host"] ?? "api.lil.tech"}`;
  }
};

/** The request's path, without its query. */
const requestPath = (request: HttpServerRequest.HttpServerRequest) =>
  request.url.split("?", 1)[0] ?? "/";

const notFound = HttpServerResponse.empty({ status: 404 });

/**
 * Keeps the API and the MCP servers on their own hosts in prod and staging: the MCP host
 * (`mcp.lil.tech`) serves only the MCP servers and their metadata, and other hosts never serve
 * those. Everything else 404s. On workers.dev, which has one host, every route is on it.
 */
export const AgentHostsMiddleware = HttpRouter.middleware(
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    return <E, R>(httpEffect: Effect.Effect<HttpServerResponse.HttpServerResponse, E, R>) =>
      HttpServerRequest.HttpServerRequest.use((request) => {
        const hosts = agentHosts(environment, requestOrigin(request));
        if (hosts.shared) return httpEffect;
        const onMcpHost = requestOrigin(request) === hosts.mcp;
        return onMcpHost === isMcpPath(requestPath(request))
          ? httpEffect
          : Effect.succeed(notFound);
      });
  }),
  { global: true },
);

/** Lets any origin call a route, without credentials, answering `OPTIONS` preflights. */
const cors = (method: "GET" | "POST") =>
  HttpMiddleware.cors({ allowedMethods: [method], maxAge: 24 * 60 * 60 });

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

/**
 * The authorization server's metadata, on the API's host. Its endpoints come in later tickets
 * (851-2848, 851-2849).
 */
const authorizationServerMetadata = (issuer: string) => ({
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
  scopes_supported: agentScopes,
});

/**
 * The agents' metadata documents and `POST /oauth/register`, only where agents may connect
 * (`agentAccessEnvironments`); elsewhere they're a 404.
 */
export const AgentOAuthRoutes = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    if (!agentAccessEnvironments.has(environment)) return;
    const clients = yield* OAuthClients;
    const limits = yield* RateLimits;
    const hostsOf = HttpServerRequest.HttpServerRequest.use((request) =>
      Effect.succeed(agentHosts(environment, requestOrigin(request))),
    );

    yield* addPublic(
      router,
      "GET",
      authorizationServerMetadataPath,
      Effect.map(hostsOf, (hosts) => document(authorizationServerMetadata(hosts.issuer))),
    );

    for (const key of Object.keys(agentResources) as Array<keyof typeof agentResources>) {
      const resource = agentResources[key];
      yield* addPublic(
        router,
        "GET",
        protectedResourceMetadataPath(key),
        Effect.map(hostsOf, (hosts) =>
          document({
            resource: resourceUrl(hosts, key),
            // The one authorization server for every app. Claude only reads the first.
            authorization_servers: [hosts.issuer],
            scopes_supported: resource.scopes,
            bearer_methods_supported: ["header"],
            resource_name: resource.name,
            resource_documentation: agentsHelpUrl(environment),
          }),
        ),
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
        const body = yield* request.text.pipe(Effect.orDie);
        // Sent without a length (chunked): checked once read.
        if (new TextEncoder().encode(body).byteLength > maxRegistrationBytes) return tooLarge;
        const metadata = yield* checkRegistration(body);
        const client = yield* clients.register(metadata).pipe(Effect.orDie);
        return HttpServerResponse.jsonUnsafe(
          {
            client_id: client.clientId,
            client_id_issued_at: Math.floor(client.createdAt / 1000),
            ...(client.name === null ? {} : { client_name: client.name }),
            ...(client.clientUri === null ? {} : { client_uri: client.clientUri }),
            redirect_uris: client.redirectUris,
            grant_types: metadata.grantTypes,
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
  }),
);
