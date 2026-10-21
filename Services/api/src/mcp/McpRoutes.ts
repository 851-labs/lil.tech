import { Effect, Option, Schema } from "effect";
import { Headers, HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { Deployment } from "../Deployment.ts";
import { AgentTokens, type InvalidAgentToken } from "../oauth/AgentTokens.ts";
import {
  agentAccessEnvironments,
  agentHosts,
  type AgentResource,
  agentResources,
  protectedResourceMetadataPath,
  resourceUrl,
} from "../oauth/Hosts.ts";
import { readAtMost, requestOrigin } from "../oauth/Requests.ts";
import { RateLimits, tooManyRequests } from "../RateLimits.ts";
import { UserStores } from "../store/UserStores.ts";
import { agentClientHeader, agentGrantHeader, agentScopesHeader } from "./AgentHeaders.ts";

// Each app's MCP server on the MCP host (`https://mcp.lil.tech/health`, 851-2851): the Worker
// checks the agent's token, its grant's scope and its rate limit, then hands the request to the
// user's store, which runs the server (`src/health/tools/HealthMcpServer.ts`). Left out of the
// OpenAPI spec: MCP is its own protocol.

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
 * One app's MCP server. Requests from browsers (with an `Origin`) are refused with 403, as the
 * transport requires; only `POST` and `DELETE` (ending a legacy session) are served.
 */
const mcpRoute = (key: AgentResource) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    const tokens = yield* AgentTokens;
    const stores = yield* UserStores;
    const limits = yield* RateLimits;
    const { scopes } = agentResources[key];
    return Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest;
      if (request.headers["origin"] !== undefined) {
        return HttpServerResponse.empty({ status: 403 });
      }
      if (request.method !== "POST" && request.method !== "DELETE") {
        return HttpServerResponse.empty({ status: 405, headers: { allow: "POST, DELETE" } });
      }
      const hosts = agentHosts(environment, requestOrigin(request));
      const metadataUrl = `${hosts.mcp}${protectedResourceMetadataPath(key)}`;
      const scope = scopes.join(" ");
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
      // Only this app's agent tokens: another app's, and the apps' own tokens, are invalid.
      const verified = yield* tokens.verify(token, resourceUrl(hosts, key)).pipe(
        Effect.map((grant) => ({ grant })),
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
      const { grant } = verified;
      // Tokens for the app always carry its scope; a grant without it can't call anything.
      if (!scopes.every((needed) => grant.scopes.includes(needed))) {
        return refuse(403, {
          code: "insufficient_scope",
          description: `This server needs ${scope}`,
        });
      }
      yield* limits.check("agent", grant.id);
      // MCP messages are small. The store holds a body in memory, so a large one is refused here.
      const tooLarge = HttpServerResponse.empty({ status: 413 });
      if (Number(request.headers["content-length"] ?? 0) > maxMcpRequestBytes) return tooLarge;
      const body =
        request.method === "POST"
          ? yield* readAtMost(request.stream, maxMcpRequestBytes).pipe(Effect.option)
          : Option.some(Option.none<string>());
      if (Option.isNone(body)) return HttpServerResponse.empty({ status: 400 });
      if (request.method === "POST" && Option.isNone(body.value)) return tooLarge;
      // An agent's first read, which the apps show, even within minutes of connecting.
      if (Option.isSome(body.value) && Option.isSome(decodeToolCall(body.value.value))) {
        yield* tokens.recordFirstUse(grant);
      }
      // Set here, over any a client sent; the token itself stays with the Worker.
      const headers = Headers.setAll(Headers.remove(request.headers, "authorization"), {
        [agentGrantHeader]: grant.id,
        [agentClientHeader]: encodeURIComponent(grant.clientName ?? grant.clientId),
        [agentScopesHeader]: grant.scopes.join(" "),
      });
      return yield* stores.mcp(
        grant.userId,
        HttpServerRequest.fromWeb(
          new Request(new URL(request.url, requestOrigin(request)), {
            method: request.method,
            headers: headers as Record<string, string>,
            ...(Option.isSome(body.value) ? { body: body.value.value } : {}),
          }),
        ),
      );
    }).pipe(Effect.catchTag("TooManyRequests", tooManyRequests));
  });

/** Every app's MCP server, only where agents may connect (`agentAccessEnvironments`). */
export const AgentMcpRoutes = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const { environment } = yield* Deployment;
    if (!agentAccessEnvironments.has(environment)) return;
    for (const key of Object.keys(agentResources) as Array<AgentResource>) {
      yield* router.add("*", agentResources[key].path, yield* mcpRoute(key));
    }
  }),
);
