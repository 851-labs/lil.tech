import { stageDomains } from "../Deployment.ts";
import type { Environment } from "../Status.ts";

// Where agents find the authorization server and each app's MCP server (851-2845,
// `docs/decisions/accounts.md`, Agents): one authorization server for every lil app, on the API's
// host, and a protected resource per app on the MCP host (`mcp.lil.tech`).

/**
 * Where agents can connect: the OAuth and MCP routes exist only here, and elsewhere are a 404. Prod
 * is added by the launch (851-2855), once the privacy policy covers it.
 */
export const agentAccessEnvironments: ReadonlySet<Environment> = new Set([
  "preview",
  "local",
  "staging",
]);

/**
 * Each app's MCP server: its path on the MCP host (its protected resource is that URL), and the
 * scopes its tokens can carry, each with the app's prefix so later apps' can't collide.
 */
export const agentResources = {
  health: { path: "/health", name: "lil health", scopes: ["health:read"] },
} as const satisfies Record<
  string,
  {
    readonly path: `/${string}`;
    readonly name: string;
    readonly scopes: ReadonlyArray<`${string}:${string}`>;
  }
>;

export type AgentResource = keyof typeof agentResources;

/** Every app's scopes, which the authorization server's metadata lists. */
export const agentScopes: ReadonlyArray<string> = Object.values(agentResources).flatMap(
  (resource) => resource.scopes,
);

/** Where an app's Protected Resource Metadata (RFC 9728) is, relative to the MCP host. */
export const protectedResourceMetadataPath = (resource: AgentResource) =>
  `/.well-known/oauth-protected-resource${agentResources[resource].path}` as const;

export const authorizationServerMetadataPath = "/.well-known/oauth-authorization-server";

/** The origins agents use, for a request to `requestOrigin`. */
export interface AgentHosts {
  /** The authorization server's issuer, the API's origin. */
  readonly issuer: string;
  /** The MCP servers' origin. */
  readonly mcp: string;
  /** Whether both are one origin (workers.dev, `alchemy dev`), so every route is on every host. */
  readonly shared: boolean;
}

/**
 * The hosts for `environment`. Prod and staging take them from their custom domains
 * (`stageDomains`), since a document on one host names the other. Elsewhere (previews, personal
 * stages, `alchemy dev`) there's one host, so both are the request's origin.
 */
export const agentHosts = (environment: Environment, requestOrigin: string): AgentHosts => {
  const domains = stageDomains[environment];
  if (domains === undefined) return { issuer: requestOrigin, mcp: requestOrigin, shared: true };
  return { issuer: `https://${domains.api}`, mcp: `https://${domains.mcp}`, shared: false };
};

/** The URL of an app's MCP server: its protected resource, and its tokens' audience. */
export const resourceUrl = (hosts: AgentHosts, resource: AgentResource) =>
  `${hosts.mcp}${agentResources[resource].path}`;

/** Whether `path` belongs on the MCP host: an app's MCP server, or its metadata. */
export const isMcpPath = (path: string) =>
  Object.values(agentResources).some(
    (resource) =>
      path === resource.path ||
      path.startsWith(`${resource.path}/`) ||
      path === `/.well-known/oauth-protected-resource${resource.path}`,
  );

/** The help page that Protected Resource Metadata's `resource_documentation` points to (851-2855). */
export const agentsHelpUrl = (environment: Environment) =>
  `https://${stageDomains[environment]?.site ?? "lil.tech"}/agents`;
