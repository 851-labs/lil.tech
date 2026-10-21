// Headers the Worker sets on a request it forwards to a user's MCP server, once it has checked the
// agent's token (`McpRoutes.ts`). The store trusts them: only the Worker can reach it, and the
// Worker overwrites any a client sent. Then the headers of the store's answer, for the Worker.

/** The grant (`agr_…`) the token belongs to. */
export const agentGrantHeader = "x-lil-agent-grant";

/** The agent's name as the consent page showed it, URI-encoded, since headers are Latin-1. */
export const agentClientHeader = "x-lil-agent-client";

/** The grant's scopes, space-separated. */
export const agentScopesHeader = "x-lil-agent-scopes";

/**
 * On the store's answer to a tool call: the tool (its name in the app's toolkit), for the Worker's
 * log line (851-2907). The Worker removes it before answering the agent.
 */
export const agentToolHeader = "x-lil-agent-tool";

/** On the store's answer to a tool call: the size of the tool's answer as JSON, in bytes. */
export const agentAnswerBytesHeader = "x-lil-agent-answer-bytes";
