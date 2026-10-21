import { Cache, Clock, Effect } from "effect";
import { McpSchema, McpServer } from "effect/ai";
import { HttpServerRequest, HttpServerResponse } from "effect/http";
import type { AgentAppRegistry } from "../oauth/Hosts.ts";
import { agentScopesHeader } from "./AgentHeaders.ts";
import { serveStoreMcp, type StoreMcpApp, type StoreMcpHandler } from "./StoreMcpServer.ts";

// The combined MCP server (851-2900, `docs/decisions/server.md`): every app's tools at the MCP
// host's root, `https://mcp.lil.tech`, each named `<app>.<tool>` as `lil mcp` names them
// (`health.summary`). It runs in the user's store, beside each app's own server, and serves the
// apps whose scopes the Worker forwarded (`x-lil-agent-scopes`).

/** Where the server is, on the MCP host and in the store's `fetch`. */
export const combinedMcpPath = "/";

/**
 * Between an app's key and its tool's name (`health.summary`), as in `lil mcp`
 * (`LilMCPServer.separator`). The MCP spec allows dots in tool names, and real clients take them.
 * App keys have none, so a name splits at its first.
 */
export const toolNameSeparator = ".";

/** `tool`'s name on the combined server. */
export const combinedToolName = (app: string, tool: string) => `${app}${toolNameSeparator}${tool}`;

/**
 * `server`, but registering each tool under `app`'s name: its schemas, annotations and handler
 * unchanged. Resources keep their URIs, which each app's scheme already sets apart, as in
 * `lil mcp`.
 */
const namespaced = (
  server: McpServer.McpServer["Service"],
  app: string,
): McpServer.McpServer["Service"] =>
  McpServer.McpServer.of({
    ...server,
    addTool: (options) =>
      server.addTool({
        ...options,
        tool: new McpSchema.Tool({
          name: combinedToolName(app, options.tool.name),
          title: options.tool.title,
          description: options.tool.description,
          inputSchema: options.tool.inputSchema,
          outputSchema: options.tool.outputSchema,
          annotations: options.tool.annotations,
          icons: options.tool.icons,
          _meta: options.tool._meta,
        }),
      }),
  });

/** What the combined server tells agents: how tools are named, then each app's instructions. */
const instructionsFor = (
  keys: ReadonlyArray<string>,
  registry: AgentAppRegistry,
  apps: Readonly<Record<string, StoreMcpApp>>,
) =>
  [
    `Read-only access to the user's lil apps. Each tool is named <app>${toolNameSeparator}<tool>, ` +
      `after the app it reads: ${keys
        .map((key) => `${key} is ${registry[key]?.name ?? key}`)
        .join(", ")}. Each app's own instructions follow, under its name.`,
    ...keys.map((key) => `## ${registry[key]?.name ?? key}\n\n${apps[key]?.instructions ?? ""}`),
  ].join("\n\n");

/**
 * The combined server for one store, as an HTTP handler at `combinedMcpPath`. A request reaches
 * the tools of the apps whose scopes it carries (`x-lil-agent-scopes`, which only the Worker sets),
 * so they're all an agent lists, and calling another app's tool is an unknown tool. Each set of
 * apps is a server of its own, built on its first request: Effect's server lists every tool it
 * has, whoever asks. A legacy session belongs to its set's server, so one whose grant loses an app
 * gets a 404 and starts again, without that app's tools.
 */
export const makeCombinedMcpServer = (options: {
  /** The apps agents can read, whose scopes say which a request may. */
  readonly registry: AgentAppRegistry;
  /** Each app's tools in this store, by key. */
  readonly apps: Readonly<Record<string, StoreMcpApp>>;
}): Effect.Effect<StoreMcpHandler> =>
  Effect.gen(function* () {
    const { registry, apps } = options;
    const keys = Object.keys(apps).filter((key) => registry[key] !== undefined);
    const clock = yield* Clock.Clock;
    // One server per set of apps, by their keys in the registry's order. Never evicted: there are
    // at most 2^apps sets, each built once, and evicting one would end its sessions.
    const servers = yield* Cache.make({
      capacity: 2 ** keys.length,
      lookup: (set: string) => {
        const included = set.split(" ");
        return serveStoreMcp({
          name: "lil",
          instructions: instructionsFor(included, registry, apps),
          path: combinedMcpPath,
          register: Effect.gen(function* () {
            const server = yield* McpServer.McpServer;
            for (const key of included) {
              yield* apps[key]!.register.pipe(
                Effect.provideService(McpServer.McpServer, namespaced(server, key)),
              );
            }
          }),
        }).pipe(Effect.provideService(Clock.Clock, clock));
      },
    });
    return Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest;
      const scopes = (request.headers[agentScopesHeader] ?? "").split(" ");
      const included = keys.filter((key) =>
        registry[key]!.scopes.some((scope: string) => scopes.includes(scope)),
      );
      // The Worker refuses a grant without any app's scope first.
      if (included.length === 0) return HttpServerResponse.empty({ status: 403 });
      return yield* yield* Cache.get(servers, included.join(" "));
    });
  });
