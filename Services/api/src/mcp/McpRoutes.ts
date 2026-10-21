import { Clock, Effect, Option, Schema } from "effect";
import { Headers, HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import type { SqlError } from "effect/sql";
import type { AgentGrant } from "../core/AgentGrants.ts";
import { Consents } from "../core/Consents.ts";
import { Deployment } from "../Deployment.ts";
import { AgentTokens, type InvalidAgentToken } from "../oauth/AgentTokens.ts";
import {
  type AgentApp,
  type AgentAppRegistry,
  AgentApps,
  agentAccessEnvironments,
  agentHosts,
  type AgentHosts,
  agentResources,
  appMetadataPath,
  appUrl,
  combinedAgentEnvironments,
  combinedResourceMetadataPath,
  combinedResourceUrl,
  scopesOf,
} from "../oauth/Hosts.ts";
import { readAtMost, requestOrigin } from "../oauth/Requests.ts";
import { RateLimits, tooManyRequests } from "../RateLimits.ts";
import { UserStores } from "../store/UserStores.ts";
import {
  agentAnswerBytesHeader,
  agentClientHeader,
  agentGrantHeader,
  agentScopesHeader,
  agentToolHeader,
} from "./AgentHeaders.ts";
import { combinedMcpPath } from "./CombinedMcpServer.ts";

// Each app's MCP server on the MCP host (`https://mcp.lil.tech/health`, 851-2851), and the
// combined one at its root (`https://mcp.lil.tech`, 851-2900): the Worker checks the agent's
// token, its grant's scopes and its rate limit, then hands the request to the user's store, which
// runs the server (`src/mcp/StoreMcpServers.ts`). Left out of the OpenAPI spec: MCP is its own
// protocol.

/** The largest MCP request the Worker forwards. */
export const maxMcpRequestBytes = 64 * 1024;

/**
 * The bearer challenge an agent gets with a 401 or 403 (RFC 6750 §3, RFC 9728 §5.1): where the
 * app's Protected Resource Metadata is, which starts sign-in, and the scope it needs. `error` only
 * when a token was sent.
 */
const challenge = (
  metadataUrl: string,
  scope: string,
  error?: { readonly code: string; readonly description: string },
) =>
  [
    `Bearer resource_metadata="${metadataUrl}"`,
    `scope="${scope}"`,
    ...(error === undefined
      ? []
      : [`error="${error.code}"`, `error_description="${error.description}"`]),
  ].join(", ");

/**
 * A request body that's a tool call: an agent reading. The protocols served have no JSON-RPC
 * batches, so a body is one message.
 */
const decodeToolCall = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Struct({ method: Schema.Literal("tools/call") })),
);

const tokenRefused = (reason: InvalidAgentToken["reason"]) => ({
  code: "invalid_token",
  description:
    reason === "expired" ? "The access token expired" : "The access token is invalid or revoked",
});

/**
 * Logs a tool call the store answered (851-2907): the tool and the answer's size, which the store
 * put in its response's headers (`agentToolHeader`), the grant, and how long the store took to
 * answer since the Worker forwarded the call (`forwardedAt`). That includes the call's wait for its
 * turn in the store, which runs its calls one at a time. The store can't time a call itself:
 * Workers doesn't move its clock while code runs, and a call reads SQLite without waiting on I/O,
 * so its clock said the call took 0 ms. The Worker waits on the store, which does move it. The
 * headers aren't passed on to the agent.
 */
const logToolCall = (
  response: HttpServerResponse.HttpServerResponse,
  grant: AgentGrant,
  forwardedAt: number,
) =>
  Effect.gen(function* () {
    const tool = response.headers[agentToolHeader];
    if (tool === undefined) return response;
    const durationMs = (yield* Clock.currentTimeMillis) - forwardedAt;
    const bytes = Number(response.headers[agentAnswerBytesHeader]);
    yield* Effect.logInfo("Agent tool call").pipe(
      Effect.annotateLogs({ tool, grant: grant.id, durationMs, bytes }),
    );
    return response.pipe(
      HttpServerResponse.removeHeader(agentToolHeader),
      HttpServerResponse.removeHeader(agentAnswerBytesHeader),
    );
  });

/** An MCP server on the MCP host, as the Worker checks requests to it. */
interface McpServerRoute {
  /** Its path, on the MCP host and in the store. */
  readonly path: `/${string}`;
  /** Where its Protected Resource Metadata is, relative to the MCP host. */
  readonly metadataPath: string;
  /** Its protected resource: its tokens' audience. */
  readonly resource: (hosts: AgentHosts) => string;
  /** The scopes a 401's challenge asks for. */
  readonly scopes: ReadonlyArray<string>;
  /**
   * The scopes of `grant` that the server may use, which the store gets: none is 403
   * `insufficient_scope`, with `insufficient` as its description.
   */
  readonly usable: (grant: AgentGrant) => Effect.Effect<ReadonlyArray<string>, SqlError.SqlError>;
  readonly insufficient: string;
}

/** One app's own server. Tokens for it always carry its scopes. */
const appServer = (app: AgentApp): McpServerRoute => ({
  path: app.path,
  metadataPath: appMetadataPath(app),
  resource: (hosts) => appUrl(hosts, app),
  scopes: app.scopes,
  usable: (grant) =>
    Effect.succeed(app.scopes.every((needed) => grant.scopes.includes(needed)) ? grant.scopes : []),
  insufficient: `This server needs ${app.scopes.join(" ")}`,
});

/**
 * The combined server (851-2900): the apps whose scopes the grant has, while the agents consent
 * (`agents:<app>`) it was allowed under stands, read on every request. Turning off an app's agent
 * access takes its scope away from combined grants (851-2901), and this cuts them off from it
 * too, as a second check, and connecting an agent again later (a new consent) doesn't bring them
 * back.
 */
const combinedServer = (
  registry: AgentAppRegistry,
  consents: Consents["Service"],
): McpServerRoute => ({
  path: combinedMcpPath,
  metadataPath: combinedResourceMetadataPath,
  resource: combinedResourceUrl,
  scopes: scopesOf(registry),
  usable: (grant) =>
    Effect.gen(function* () {
      const scopesOfApp = (key: string): ReadonlyArray<string> => registry[key]?.scopes ?? [];
      const apps = Object.keys(registry).filter((key) =>
        scopesOfApp(key).some((scope) => grant.scopes.includes(scope)),
      );
      // Given when it was allowed, so by the time the grant was made.
      const given = yield* consents.inForce(
        grant.userId,
        apps.map((key) => registry[key]!.consent),
        grant.createdAt,
      );
      const readable = apps.filter((key) => given.has(registry[key]!.consent));
      return grant.scopes.filter((scope) =>
        readable.some((key) => scopesOfApp(key).includes(scope)),
      );
    }),
  insufficient: "This agent may no longer read any lil app. Connect it again to allow it.",
});

/**
 * An MCP server's route. Requests from browsers (with an `Origin`) are refused with 403, as the
 * transport requires; only `POST` and `DELETE` (ending a legacy session) are served.
 */
const mcpRoute = (server: McpServerRoute) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    const tokens = yield* AgentTokens;
    const stores = yield* UserStores;
    const limits = yield* RateLimits;
    return Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest;
      if (request.headers["origin"] !== undefined) {
        return HttpServerResponse.empty({ status: 403 });
      }
      if (request.method !== "POST" && request.method !== "DELETE") {
        return HttpServerResponse.empty({ status: 405, headers: { allow: "POST, DELETE" } });
      }
      const hosts = agentHosts(environment, requestOrigin(request));
      const metadataUrl = `${hosts.mcp}${server.metadataPath}`;
      const scope = server.scopes.join(" ");
      const refuse = (
        status: 401 | 403,
        error?: { readonly code: string; readonly description: string },
      ) =>
        HttpServerResponse.jsonUnsafe(
          error === undefined
            ? { error_description: "An access token is required" }
            : { error: error.code, error_description: error.description },
          {
            status,
            headers: {
              "www-authenticate": challenge(metadataUrl, scope, error),
              "cache-control": "no-store",
            },
          },
        );
      // Only in the header (RFC 6750 §2.1), never the query string.
      const token = /^Bearer +(\S+) *$/i.exec(request.headers["authorization"] ?? "")?.[1];
      if (token === undefined) return refuse(401);
      // Only this server's agent tokens: another server's, and the apps' own tokens, are invalid.
      const verified = yield* tokens.verify(token, server.resource(hosts)).pipe(
        // Counted once the token is good, before anything else reads the database.
        Effect.tap((grant) => limits.check("agent", grant.id)),
        Effect.flatMap((grant) =>
          Effect.map(server.usable(grant), (scopes) => ({ grant, scopes })),
        ),
        Effect.catchTag("InvalidAgentToken", (error: InvalidAgentToken) =>
          Effect.succeed({ refused: tokenRefused(error.reason) }),
        ),
        // The database failed, so the client should try again, not sign in again.
        Effect.catchTag("SqlError", (error) =>
          Effect.logWarning("Checking an agent token failed", error).pipe(
            Effect.as({ unavailable: true as const }),
          ),
        ),
      );
      if ("unavailable" in verified) {
        return HttpServerResponse.jsonUnsafe(
          { error: "temporarily_unavailable", error_description: "Try again in a moment" },
          { status: 503, headers: { "retry-after": "5", "cache-control": "no-store" } },
        );
      }
      if ("refused" in verified) return refuse(401, verified.refused);
      const { grant, scopes } = verified;
      // A grant left without a scope the server serves can't call anything.
      if (scopes.length === 0) {
        return refuse(403, { code: "insufficient_scope", description: server.insufficient });
      }
      // MCP messages are small. The store holds a body in memory, so a large one is refused here.
      const tooLarge = HttpServerResponse.empty({ status: 413 });
      if (Number(request.headers["content-length"] ?? 0) > maxMcpRequestBytes) return tooLarge;
      const body =
        request.method === "POST"
          ? yield* readAtMost(request.stream, maxMcpRequestBytes).pipe(Effect.option)
          : Option.some(Option.none<string>());
      if (Option.isNone(body)) return HttpServerResponse.empty({ status: 400 });
      if (request.method === "POST" && Option.isNone(body.value)) return tooLarge;
      // Whether this is the agent's first read, which the apps show, even within minutes of
      // connecting. Only decoded until one is recorded.
      const firstRead =
        grant.firstUsedAt === null &&
        Option.isSome(body.value) &&
        Option.isSome(decodeToolCall(body.value.value));
      // Set here, over any a client sent; the token itself stays with the Worker.
      const headers = Headers.setAll(Headers.remove(request.headers, "authorization"), {
        [agentGrantHeader]: grant.id,
        [agentClientHeader]: encodeURIComponent(grant.clientName ?? grant.clientId),
        [agentScopesHeader]: scopes.join(" "),
      });
      // The Worker's clock moves while it waits for the store, which the store's own doesn't.
      const forwarded = yield* Clock.currentTimeMillis;
      const answer = yield* stores.mcp(
        grant.userId,
        HttpServerRequest.fromWeb(
          new Request(new URL(request.url, requestOrigin(request)), {
            method: request.method,
            headers: headers as Record<string, string>,
            ...(Option.isSome(body.value) ? { body: body.value.value } : {}),
          }),
        ),
      );
      const response = yield* logToolCall(answer, grant, forwarded);
      // Once the server took the call (and logged it), not one it refused, such as a request in
      // a session it forgot.
      if (firstRead && response.status >= 200 && response.status < 300) {
        yield* tokens.recordFirstUse(grant);
      }
      return response;
    }).pipe(Effect.catchTag("TooManyRequests", tooManyRequests));
  });

/**
 * Every app's MCP server, only where agents may connect (`agentAccessEnvironments`), and the
 * combined one where it's allowed (`combinedAgentEnvironments`).
 */
export const AgentMcpRoutes = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    if (!agentAccessEnvironments.has(environment)) return;
    for (const app of Object.values(agentResources)) {
      yield* router.add("*", app.path, yield* mcpRoute(appServer(app)));
    }
    if (combinedAgentEnvironments.has(environment)) {
      const server = combinedServer(yield* AgentApps, yield* Consents);
      yield* router.add("*", server.path, yield* mcpRoute(server));
    }
  }),
);
