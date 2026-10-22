import { Context, Option } from "effect";
import { stageDomains } from "../Deployment.ts";
import { agentsConsentPolicyVersions, type ConsentType } from "../core/Consents.ts";
import type { Environment } from "../Status.ts";

// Where agents find the authorization server and each app's MCP server (851-2845,
// `docs/decisions/accounts.md`, Agents): one authorization server for every lil app, on the API's
// host, a protected resource per app on the MCP host (`mcp.lil.tech/health`), and one for every
// app at once, the combined server at the MCP host's root (`mcp.lil.tech`, 851-2899).

/**
 * Where agents can connect: the OAuth and MCP routes exist only here, and elsewhere are a 404.
 * Every environment since the launch (851-2855), once the privacy policy covered it. A new
 * environment opts in here, and in `combinedAgentEnvironments` for the combined server.
 */
export const agentAccessEnvironments: ReadonlySet<Environment> = new Set([
  "preview",
  "local",
  "staging",
  "prod",
]);

/**
 * Where agents can connect to the combined server (`https://mcp.lil.tech`, 851-2899): its metadata,
 * authorizing it and its MCP route exist only here. Every environment since its launch (851-2903),
 * once the privacy policy described it and both apps could list and revoke its agents. A subset of
 * `agentAccessEnvironments`.
 */
export const combinedAgentEnvironments: ReadonlySet<Environment> = new Set([
  "preview",
  "local",
  "staging",
  "prod",
]);

/** An app agents can read, through its own MCP server or the combined one. */
export interface AgentApp {
  /** Its MCP server's path on the MCP host; its protected resource is that URL. */
  readonly path: `/${string}`;
  readonly name: string;
  /** The scopes its tokens can carry, each with the app's prefix so later apps' can't collide. */
  readonly scopes: ReadonlyArray<`${string}:${string}`>;
  /** The consent connecting an agent records (`Consents.ts`). */
  readonly consent: ConsentType;
  /** The privacy policy version that consent is recorded against. */
  readonly consentPolicyVersion: string;
}

/** Every app agents can read, by key (`health`). */
export type AgentAppRegistry = Readonly<Record<string, AgentApp>>;

/** Each app's MCP server. A later app joins the combined server just by being here. */
export const agentResources = {
  health: {
    path: "/health",
    name: "lil health",
    scopes: ["health:read"],
    consent: "agents:health",
    consentPolicyVersion: agentsConsentPolicyVersions["agents:health"],
  },
} as const satisfies AgentAppRegistry;

export type AgentResource = keyof typeof agentResources;

/**
 * The apps the authorization server knows: `agentResources`, swapped in tests for a registry with
 * a second app, since only lil health exists.
 */
export const AgentApps = Context.Reference<AgentAppRegistry>("lil/api/oauth/AgentApps", {
  defaultValue: () => agentResources,
});

/** The app a request without a `resource` is for, as before the combined server existed. */
export const defaultAgentApp = "health";

/** Every app's scopes, which the metadata lists. */
export const scopesOf = (registry: AgentAppRegistry): ReadonlyArray<string> =>
  Object.values(registry).flatMap((app) => app.scopes);

/** Where an app's Protected Resource Metadata (RFC 9728) is, relative to the MCP host. */
export const protectedResourceMetadataPath = (resource: AgentResource) =>
  appMetadataPath(agentResources[resource]);

/** Where the combined server's Protected Resource Metadata is: the root that RFC 9728 gives it. */
export const combinedResourceMetadataPath = "/.well-known/oauth-protected-resource";

/** Where `app`'s Protected Resource Metadata is, relative to the MCP host. */
export const appMetadataPath = (app: AgentApp) =>
  `${combinedResourceMetadataPath}${app.path}` as const;

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
  appUrl(hosts, agentResources[resource]);

/** The URL of `app`'s MCP server, on these hosts. */
export const appUrl = (hosts: AgentHosts, app: AgentApp) => `${hosts.mcp}${app.path}`;

/**
 * The app whose MCP server `resource` is, on these hosts, if it's one. Exactly its URL, as its
 * Protected Resource Metadata gives it, since the token endpoint compares resources as strings.
 */
export const resourceFor = (hosts: AgentHosts, resource: string): Option.Option<AgentResource> =>
  Option.fromNullishOr(
    (Object.keys(agentResources) as Array<AgentResource>).find(
      (key) => resourceUrl(hosts, key) === resource,
    ),
  );

/**
 * The combined server's URL, `https://mcp.lil.tech`: its protected resource, and its tokens'
 * audience. Canonical without a trailing slash, as MCP's server URIs are.
 */
export const combinedResourceUrl = (hosts: AgentHosts) => hosts.mcp;

/**
 * `resource` in its canonical form: an origin with a trailing slash (the combined server's URL as
 * some clients send it, once they've parsed it) is that origin. Anything else is as given, since
 * resources are compared as strings. It doesn't depend on the request's host, so a token request
 * that reaches another origin than its authorization (`alchemy dev` behind a tunnel) still matches.
 */
export const canonicalResource = (resource: string) => {
  if (!resource.endsWith("/") || !URL.canParse(resource)) return resource;
  const { origin } = new URL(resource);
  return resource === `${origin}/` ? origin : resource;
};

/** What an authorization is for: a resource, and the apps its tokens may read there. */
export interface AgentTarget {
  /** The resource, in its canonical form: its tokens' audience. */
  readonly resource: string;
  /** Whether it's the combined server, for every app, rather than one app's own. */
  readonly combined: boolean;
  /** The apps it can read (keys of the registry): one app's, or all of them. */
  readonly apps: ReadonlyArray<string>;
}

/**
 * The target `resource` names, on these hosts: one app's MCP server, exactly its URL, or the
 * combined server (with or without a trailing slash), where `combined` allows it.
 */
export const targetFor = (
  registry: AgentAppRegistry,
  hosts: AgentHosts,
  resource: string,
  combined: boolean,
): Option.Option<AgentTarget> => {
  const canonical = canonicalResource(resource);
  if (canonical === combinedResourceUrl(hosts)) {
    return combined
      ? Option.some({ resource: canonical, combined: true, apps: Object.keys(registry) })
      : Option.none();
  }
  return Option.map(
    Option.fromNullishOr(
      Object.keys(registry).find((key) => {
        const app = registry[key];
        return app !== undefined && appUrl(hosts, app) === canonical;
      }),
    ),
    (key) => ({ resource: canonical, combined: false, apps: [key] }),
  );
};

/**
 * What an authorization for `target` grants, from the scopes asked for (`scope`, space-separated):
 * those the target's apps have (others, and unknown ones, are dropped), or every one of theirs if
 * none are left. The apps are those the scopes cover, so for the combined server the scopes choose
 * the apps.
 */
export const grantFor = (registry: AgentAppRegistry, target: AgentTarget, scope: string) => {
  const known = target.apps.flatMap((key): ReadonlyArray<string> => registry[key]?.scopes ?? []);
  const asked = [...new Set(scope.split(" ").filter((name) => known.includes(name)))];
  const scopes = asked.length === 0 ? known : asked;
  return {
    scopes,
    apps: appsOfScopes(registry, target, scopes),
  };
};

/** The apps of `target` that `scopes` cover: those with at least one of them. */
export const appsOfScopes = (
  registry: AgentAppRegistry,
  target: AgentTarget,
  scopes: ReadonlyArray<string>,
): ReadonlyArray<string> =>
  target.apps.filter((key) =>
    (registry[key]?.scopes ?? []).some((name: string) => scopes.includes(name)),
  );

/**
 * The app (a key of the registry) whose MCP server a stored grant's or authorization's `resource`
 * is, by its path alone. Authorizing already checked the whole URL, and the apps' requests may come
 * to another origin than the agent's (`alchemy dev` behind a tunnel), so the path is what's left to
 * tell apps apart.
 */
export const appOfResource = (
  registry: AgentAppRegistry,
  resource: string,
): Option.Option<string> => {
  if (!URL.canParse(resource)) return Option.none();
  const { pathname } = new URL(resource);
  return Option.fromNullishOr(
    Object.keys(registry).find((key) => registry[key]?.path === pathname),
  );
};

/**
 * Whether a stored grant's or authorization's `resource` is the combined server's: an origin, with
 * no path, as it's stored (`canonicalResource`). By its form alone, like `appOfResource`.
 */
export const isCombinedResource = (resource: string) =>
  URL.canParse(resource) && new URL(resource).origin === resource;

/**
 * The apps (keys of the registry) a stored grant can read now, from its scopes: its own server's
 * app, or, for the combined server, each app it holds a scope of. An app's Turn Off Agent Access
 * takes its scopes away from combined grants (851-2901), so they're what the grant can read.
 */
export const appsOfGrant = (
  registry: AgentAppRegistry,
  grant: { readonly resource: string; readonly scopes: ReadonlyArray<string> },
): ReadonlyArray<string> => {
  const combined = isCombinedResource(grant.resource);
  const apps = combined
    ? Object.keys(registry)
    : Option.toArray(appOfResource(registry, grant.resource));
  return appsOfScopes(registry, { resource: grant.resource, combined, apps }, grant.scopes);
};

/**
 * Whether `path` belongs on the MCP host: an app's MCP server, or its metadata, or the combined
 * server's (the root, `/`, and the root metadata, as exact paths).
 */
export const isMcpPath = (path: string, registry: AgentAppRegistry = agentResources) =>
  path === "/" ||
  path === combinedResourceMetadataPath ||
  Object.values(registry).some(
    (app) => path === app.path || path.startsWith(`${app.path}/`) || path === appMetadataPath(app),
  );

/** Whether `path` is one of the authorization server's, which only its issuer's host serves. */
export const isAuthorizationServerPath = (path: string) =>
  path === authorizationServerMetadataPath || path.startsWith("/oauth/");

/** A page of the stage's website (`Web/site/public`): prod's for stages without their own. */
export const siteUrl = (environment: Environment, path: `/${string}`) =>
  `https://${stageDomains[environment]?.site ?? "lil.tech"}${path}`;

/**
 * The help page that Protected Resource Metadata's `resource_documentation` points to
 * (`Web/site/public/agents`, 851-2855).
 */
export const agentsHelpUrl = (environment: Environment) => siteUrl(environment, "/agents");
