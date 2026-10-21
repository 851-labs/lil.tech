// Headers the Worker sets on a request it forwards to a user's MCP server, once it has checked the
// agent's token (`McpRoutes.ts`). The store trusts them: only the Worker can reach it, and the
// Worker overwrites any a client sent.

/** The grant (`agr_…`) the token belongs to. */
export const agentGrantHeader = "x-lil-agent-grant";

/** The agent's name as the consent page showed it, URI-encoded, since headers are Latin-1. */
export const agentClientHeader = "x-lil-agent-client";

/** The grant's scopes, space-separated. */
export const agentScopesHeader = "x-lil-agent-scopes";
