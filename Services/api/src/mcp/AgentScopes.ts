import { Effect, Option } from "effect";
import { HttpServerRequest } from "effect/http";
import { agentScopesHeader } from "./AgentHeaders.ts";

// The grant's scopes, as a user's store sees them: the Worker admits a grant to an app's server by
// the app's read scope alone, and forwards all of its scopes (`x-lil-agent-scopes`), so a tool
// that changes something checks its own scope on each call (851-3214).

/** The scopes in a request the Worker forwarded (`x-lil-agent-scopes`), none if it has none. */
export const scopesOfRequest = (
  request: HttpServerRequest.HttpServerRequest,
): ReadonlyArray<string> =>
  (request.headers[agentScopesHeader] ?? "").split(" ").filter((scope) => scope !== "");

/**
 * The scopes of the grant the Worker forwarded the current request for. None outside a request,
 * so a tool run any other way can't change anything.
 */
export const forwardedScopes: Effect.Effect<ReadonlyArray<string>> = Effect.map(
  Effect.serviceOption(HttpServerRequest.HttpServerRequest),
  Option.match({ onNone: () => [], onSome: scopesOfRequest }),
);

/** Succeeds if the grant holds `scope`, else fails with `missing()`. */
export const requireScope = <E>(scope: string, missing: () => E): Effect.Effect<void, E> =>
  Effect.flatMap(forwardedScopes, (scopes) =>
    scopes.includes(scope) ? Effect.void : Effect.fail(missing()),
  );
