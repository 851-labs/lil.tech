import type { StoreSql } from "./StoreSql.ts";

// The log of agents' tool calls at the user's MCP servers (851-2851, `docs/decisions/server.md`):
// which agent asked, for what, and how it went, never what it read. The apps show it (851-2852).
// It lives in the user's store, next to the data, and isn't synced.

export const agentAccessLogPolicy = {
  /** How long a row is kept. */
  retention: 90 * 24 * 60 * 60 * 1000,
  /** The most rows kept: past it, each new row replaces the oldest. */
  maxRows: 10_000,
  /**
   * How long past `retention` a row may stay before the alarm trims it, so trimming wakes the
   * store about daily rather than as each row turns 90 days old.
   */
  trimSlack: 24 * 60 * 60 * 1000,
};

export type AgentAccessLogPolicy = typeof agentAccessLogPolicy;

/**
 * How a call went: answered (`ok`), refused with the tool's error or failed (`error`), or with an
 * answer over the server's ceiling, which wasn't sent (`too_large`).
 */
export type AgentAccessOutcome = "ok" | "error" | "too_large";

/** One tool call, as the log keeps it. */
export interface AgentAccess {
  /** The grant (`agr_…`): one agent's access to one app. */
  readonly grantId: string;
  /** The agent's name, as the consent page showed it. */
  readonly clientName: string;
  readonly tool: string;
  /** The types asked for, if the tool takes any. */
  readonly types: ReadonlyArray<string> | null;
  /** The range asked for (`D`, `W`…), if the tool takes one. */
  readonly range: string | null;
  /** The day the range ends on, if one was asked for. */
  readonly date: string | null;
  readonly outcome: AgentAccessOutcome;
  /** How many rows went back: the items of the answer's lists. */
  readonly rows: number;
}

/** Adds a call to the log at `at`, dropping the oldest rows past `maxRows`. */
export const appendAgentAccess = (
  sql: StoreSql,
  access: AgentAccess,
  at: number,
  policy: AgentAccessLogPolicy = agentAccessLogPolicy,
) =>
  sql.transaction(() => {
    const [row] = sql.exec(
      `INSERT INTO agent_access_log
        (at, grant_id, client_name, tool, types, range, date, outcome, rows)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING id`,
      at,
      access.grantId,
      access.clientName,
      access.tool,
      access.types === null ? null : JSON.stringify(access.types),
      access.range,
      access.date,
      access.outcome,
      access.rows,
    );
    // IDs only grow, so the newest `maxRows` are the last IDs.
    sql.exec("DELETE FROM agent_access_log WHERE id <= ?", Number(row?.["id"]) - policy.maxRows);
  });

/** When the alarm should next trim the log: once its oldest row is past its time, or `null`. */
export const nextAgentAccessTrimAt = (
  sql: StoreSql,
  policy: AgentAccessLogPolicy = agentAccessLogPolicy,
): number | null => {
  const oldest = sql.exec("SELECT at FROM agent_access_log ORDER BY id LIMIT 1")[0]?.["at"];
  return oldest === undefined ? null : Number(oldest) + policy.retention + policy.trimSlack;
};

/** Deletes the rows older than `retention`, from the alarm. */
export const trimAgentAccessLog = (
  sql: StoreSql,
  now: number,
  policy: AgentAccessLogPolicy = agentAccessLogPolicy,
) => {
  sql.exec("DELETE FROM agent_access_log WHERE at < ?", now - policy.retention);
};
