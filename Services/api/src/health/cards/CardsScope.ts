import { requireScope } from "../../mcp/AgentScopes.ts";
import type { agentResources } from "../../oauth/Hosts.ts";
import { HealthToolError } from "../tools/HealthToolkit.ts";

// The scope agents need to change cards (851-3214, `docs/decisions/cards.md`, The consent scope).
// Reading cards and previews needs only `health:read`, which every grant has. Grants made before
// `health:cards` existed keep reading, and connect again to change cards.

/** Lets an agent create, change, delete and reorder the account's cards, never Health data. */
export const healthCardsScope =
  "health:cards" satisfies (typeof agentResources.health.scopes)[number];

/** What a card write says to an agent whose grant doesn't hold `health:cards`. */
export const missingCardsScopeMessage =
  "This agent can read lil health but not change cards. " +
  "To let it, connect it again and allow it to manage cards.";

/** Fails a card write unless the agent's grant holds `health:cards`. Each write tool runs it first. */
export const requireCardsScope = requireScope(
  healthCardsScope,
  () => new HealthToolError({ message: missingCardsScopeMessage }),
);
