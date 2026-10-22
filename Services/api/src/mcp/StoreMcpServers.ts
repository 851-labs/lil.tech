import { Effect } from "effect";
import {
  healthMcpApp,
  healthMcpPath,
  healthMcpSessionsKey,
  makeTurns,
  serveHealthMcp,
} from "../health/tools/HealthMcpServer.ts";
import { type AgentAppRegistry, agentResources } from "../oauth/Hosts.ts";
import type { AgentAccess } from "../store/AgentAccessLog.ts";
import type { AccountDeleted } from "../store/Changes.ts";
import { storeMcpSessions } from "../store/McpSessions.ts";
import type { StoreSql } from "../store/StoreSql.ts";
import { combinedMcpPath, makeCombinedMcpServer } from "./CombinedMcpServer.ts";
import type { StoreMcpApp, StoreMcpHandler } from "./StoreMcpServer.ts";

/**
 * A store's MCP servers: lil health's own (`/health`) and the combined one (`/`), sharing the
 * store's one queue of tool calls (851-2887). Gives the server at a path, if there's one.
 */
export const makeStoreMcpServers = (options: {
  readonly sql: StoreSql;
  readonly record: (access: AgentAccess) => Effect.Effect<void, AccountDeleted>;
  /** The apps agents can read (`agentResources`; tests add a fake lil mail). */
  readonly registry?: AgentAppRegistry;
  /** More apps for the combined server, beside lil health: a fake lil mail in tests. */
  readonly otherApps?: Readonly<Record<string, StoreMcpApp>>;
}) =>
  Effect.gen(function* () {
    const { sql, record } = options;
    // lil health's tools, once: both servers register the same handlers, in the same queue.
    const healthApp = healthMcpApp({ sql, record, turns: yield* makeTurns() });
    // Sessions are kept in the store's SQLite too, so they outlive its object (851-2947).
    const sessions = storeMcpSessions(sql);
    const health = yield* serveHealthMcp(healthApp, sessions(healthMcpSessionsKey));
    const combined = yield* makeCombinedMcpServer({
      registry: options.registry ?? agentResources,
      apps: { health: healthApp, ...options.otherApps },
      sessions,
    });
    return (path: string): StoreMcpHandler | undefined =>
      path === healthMcpPath ? health : path === combinedMcpPath ? combined : undefined;
  });
