import { Schema } from "effect";
import { HttpApiEndpoint, HttpApiGroup } from "effect/http-api";
import { Authorization } from "../auth/AuthApi.ts";
import { AgentGrantId } from "../core/Ids.ts";
import { documentQuery } from "../OpenApiAnnotations.ts";
import { UserStoreUnavailable } from "../store/UserStores.ts";

// The apps' view of the agents connected to the account (851-2852, `docs/decisions/accounts.md`,
// Agents): what's connected, what each read, and revoking them. Like `Api.ts`, it holds no server
// code. The OAuth and MCP routes themselves stay out of the spec; these are the apps' own.

/** The most access log entries a page holds. */
export const agentAccessLogPageSize = 100;

/** An agent connected to one app (a grant): who it is, as the consent page showed it. */
export class ConnectedAgent extends Schema.Class<ConnectedAgent>("lil/api/oauth/ConnectedAgent")({
  /** What `DELETE /v1/me/agents/{id}` takes, and what access log entries name. */
  id: AgentGrantId,
  /** The agent's name, e.g. "Claude". `null` for a registered client that gave none. */
  name: Schema.NullOr(Schema.String),
  /**
   * The domain of its Client ID Metadata Document, e.g. `claude.ai`, which vouches for the name.
   * `null` for a client that registered itself, whose name is unverified.
   */
  domain: Schema.NullOr(Schema.String),
  /** The host the user's browser returned to when it connected, e.g. `claude.ai` or `localhost`. */
  redirectHost: Schema.String,
  /**
   * The app's MCP server the agent reads, e.g. `https://mcp.lil.tech/health`. A string, not an
   * enum, so later apps' servers don't break clients.
   */
  resource: Schema.String,
  /**
   * The app it's connected to, e.g. `health`: each app lists its own. A string, not an enum, for
   * the same reason. `null` for a server this deployment doesn't know.
   */
  app: Schema.NullOr(Schema.String),
  /** Unix milliseconds. */
  connectedAt: Schema.Int,
  /**
   * Unix milliseconds: when it last used its access, recorded at most every 5 minutes. When it
   * connected, until then.
   */
  lastUsedAt: Schema.Int,
}) {}

export class ConnectedAgents extends Schema.Class<ConnectedAgents>("lil/api/oauth/ConnectedAgents")(
  {
    /** Most recently connected first, for every app: each app shows those whose `app` is its own. */
    agents: Schema.Array(ConnectedAgent),
  },
) {}

/** One tool call an agent made at an app's MCP server. Never what it read. */
export class AgentAccessEntry extends Schema.Class<AgentAccessEntry>(
  "lil/api/oauth/AgentAccessEntry",
)({
  /** The entry's place in the log: pass the last one's as `before` for older entries. */
  id: Schema.Int,
  /** Unix milliseconds. */
  at: Schema.Int,
  /** The agent's grant (`ConnectedAgent.id`), which may have been revoked since. */
  agentId: Schema.String,
  /**
   * The agent's name when it made the call, or its client ID if it gave none (a registered client,
   * whose `ConnectedAgent.name` is `null`).
   */
  agentName: Schema.String,
  /** The tool it called, e.g. `summary` or `metric`. */
  tool: Schema.String,
  /** The types it asked for, if the tool takes any. */
  types: Schema.NullOr(Schema.Array(Schema.String)),
  /** The range it asked for (`D`, `W`, `M`…), if the tool takes one. */
  range: Schema.NullOr(Schema.String),
  /** The day the range ends on (`YYYY-MM-DD`), if it asked for one. */
  date: Schema.NullOr(Schema.String),
  /**
   * How the call went: `ok`, `error` (the tool refused or failed) or `too_large` (the answer was
   * over the server's ceiling, and wasn't sent). A string, not an enum, so new outcomes don't break
   * clients.
   */
  outcome: Schema.String,
  /** How many rows the answer held. */
  rows: Schema.Int,
}) {}

export class AgentAccessLog extends Schema.Class<AgentAccessLog>("lil/api/oauth/AgentAccessLog")({
  /** Newest first, at most 100. Kept 90 days, and the newest 10,000. */
  entries: Schema.Array(AgentAccessEntry),
  /** Pass as `before` for the next, older page. `null` on the last page. */
  nextBefore: Schema.NullOr(Schema.Int),
}) {}

const AgentAccessLogQuery = {
  /** Only entries older than this one (an entry's `id`). Leave it out for the newest. */
  before: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThanOrEqualTo(1))),
};

/** Consent to an app's agents reading its data, which connecting one gives (`agents:health`). */
export class AgentsConsent extends Schema.Class<AgentsConsent>("lil/api/oauth/AgentsConsent")({
  /** The consent in force, if any. Only connecting an agent gives it. */
  given: Schema.NullOr(
    Schema.Struct({
      policyVersion: Schema.String,
      /** Unix milliseconds. */
      grantedAt: Schema.Int,
    }),
  ),
}) {}

export class AgentsApi extends HttpApiGroup.make("agents", { topLevel: true })
  .add(HttpApiEndpoint.get("connectedAgents", "/v1/me/agents", { success: ConnectedAgents }))
  .add(
    // The agents' tool calls at every app's MCP server, newest first, 100 a page. Entries outlive
    // a revoked agent.
    HttpApiEndpoint.get("agentAccessLog", "/v1/me/agents/access-log", {
      query: AgentAccessLogQuery,
      success: AgentAccessLog,
      error: UserStoreUnavailable,
    }).annotateMerge(documentQuery(AgentAccessLogQuery)),
  )
  .add(
    // Revokes an agent: its grant and tokens are deleted, so its next request is refused. Revoking
    // one that's gone already changes nothing.
    HttpApiEndpoint.delete("revokeAgent", "/v1/me/agents/:id", { params: { id: AgentGrantId } }),
  )
  .add(
    HttpApiEndpoint.get("healthAgentsConsent", "/v1/me/consents/agents/health", {
      success: AgentsConsent,
    }),
  )
  .add(
    // Turn Off Agent Access for lil health: withdraws its agents consent and revokes its agents
    // only, leaving other apps'. Connecting an agent again asks for consent again.
    HttpApiEndpoint.delete("withdrawHealthAgentsConsent", "/v1/me/consents/agents/health"),
  )
  .middleware(Authorization) {}
