import { Clock, Effect } from "effect";
import type { StoreMcpSessions } from "../mcp/StoreMcpServer.ts";
import type { StoreSql } from "./StoreSql.ts";

// Agents' MCP sessions (`Mcp-Session-Id`, the protocols before `2026-07-28`), kept in the user's
// store so they outlive its object (851-2947, `docs/decisions/server.md`): Workers takes an idle
// store out of memory after about 10 seconds, and Effect's MCP server keeps sessions in memory.
// A row is what the agent sent to start its session, which is all a server needs to start it
// again. It holds no Health data, and isn't synced or exported.

export const mcpSessionPolicy = {
  /** How long a session is kept after it began or was last brought back. */
  retention: 30 * 24 * 60 * 60 * 1000,
  /** The most sessions kept: past it, each new one replaces the one least recently used. */
  maxSessions: 1_000,
};

export type McpSessionPolicy = typeof mcpSessionPolicy;

/** Keeps a session `server` began at `at`, trimming expired sessions and those past the most. */
export const saveMcpSession = (
  sql: StoreSql,
  session: { readonly id: string; readonly server: string; readonly initialize: string },
  at: number,
  policy: McpSessionPolicy = mcpSessionPolicy,
) =>
  sql.transaction(() => {
    // Not in a deleted account's store, which keeps nothing but its mark.
    sql.exec(
      `INSERT OR REPLACE INTO mcp_sessions (id, server, initialize, used_at)
        SELECT ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM meta WHERE key = 'deleted' AND value = 1)`,
      session.id,
      session.server,
      session.initialize,
      at,
    );
    sql.exec("DELETE FROM mcp_sessions WHERE used_at < ?", at - policy.retention);
    sql.exec(
      `DELETE FROM mcp_sessions WHERE id NOT IN
        (SELECT id FROM mcp_sessions ORDER BY used_at DESC LIMIT ?)`,
      policy.maxSessions,
    );
  });

/**
 * What the agent sent to start session `id` at `server`, if the session is kept and not expired
 * at `now`. A session is its server's: another server (a combined one for other apps) has none.
 */
export const findMcpSession = (
  sql: StoreSql,
  id: string,
  server: string,
  now: number,
  policy: McpSessionPolicy = mcpSessionPolicy,
): string | undefined => {
  const row = sql.exec(
    "SELECT initialize FROM mcp_sessions WHERE id = ? AND server = ? AND used_at >= ?",
    id,
    server,
    now - policy.retention,
  )[0];
  // The table is STRICT, so the column holds text.
  return row === undefined ? undefined : (row["initialize"] as string);
};

/** Marks session `id` used at `at`, which keeps it for another `retention`. */
export const touchMcpSession = (sql: StoreSql, id: string, at: number) => {
  sql.exec("UPDATE mcp_sessions SET used_at = ? WHERE id = ?", at, id);
};

/** Forgets session `id`: the agent ended it, or it can't be started again. */
export const deleteMcpSession = (sql: StoreSql, id: string) => {
  sql.exec("DELETE FROM mcp_sessions WHERE id = ?", id);
};

/** The sessions of each of a store's MCP servers, by the server's key, in the store's SQLite. */
export const storeMcpSessions =
  (sql: StoreSql, policy: McpSessionPolicy = mcpSessionPolicy) =>
  (server: string): StoreMcpSessions => ({
    save: (id, initialize) =>
      Effect.map(Clock.currentTimeMillis, (now) =>
        saveMcpSession(sql, { id, server, initialize }, now, policy),
      ),
    find: (id) =>
      Effect.map(Clock.currentTimeMillis, (now) => findMcpSession(sql, id, server, now, policy)),
    touch: (id) => Effect.map(Clock.currentTimeMillis, (now) => touchMcpSession(sql, id, now)),
    remove: (id) => Effect.sync(() => deleteMcpSession(sql, id)),
  });
