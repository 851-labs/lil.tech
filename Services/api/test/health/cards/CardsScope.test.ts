import { assert, describe, it } from "@effect/vitest";
import { Effect, Exit } from "effect";
import { HttpServerRequest } from "effect/http";
import {
  healthCardsScope,
  missingCardsScopeMessage,
  requireCardsScope,
} from "../../../src/health/cards/CardsScope.ts";
import { HealthToolError } from "../../../src/health/tools/HealthToolkit.ts";
import { agentScopesHeader } from "../../../src/mcp/AgentHeaders.ts";
import { forwardedScopes } from "../../../src/mcp/AgentScopes.ts";
import { agentResources } from "../../../src/oauth/Hosts.ts";

// The card write tools' scope check (851-3214): the Worker forwards a grant's scopes, and a card
// write needs `health:cards`, which grants made before it existed don't hold.

/** Runs `effect` in a request the Worker forwarded with `scopes`, or none at all. */
const inRequest = <A, E>(effect: Effect.Effect<A, E>, scopes?: string) =>
  effect.pipe(
    Effect.provideService(
      HttpServerRequest.HttpServerRequest,
      HttpServerRequest.fromWeb(
        new Request("https://mcp.example/health", {
          method: "POST",
          headers: scopes === undefined ? {} : { [agentScopesHeader]: scopes },
        }),
      ),
    ),
  );

describe("health:cards", () => {
  it("is one of lil health's scopes, which every grant reads by health:read", () => {
    assert.include(agentResources.health.scopes, healthCardsScope);
    assert.strictEqual(agentResources.health.readScope, "health:read");
    assert.deepStrictEqual(Object.keys(agentResources.health.writeScopes), [healthCardsScope]);
  });

  it.effect("reads the scopes the Worker forwarded", () =>
    Effect.gen(function* () {
      assert.deepStrictEqual(yield* inRequest(forwardedScopes, "health:read health:cards"), [
        "health:read",
        "health:cards",
      ]);
      assert.deepStrictEqual(yield* inRequest(forwardedScopes, ""), []);
      assert.deepStrictEqual(yield* inRequest(forwardedScopes), []);
      // Outside a request there are none.
      assert.deepStrictEqual(yield* forwardedScopes, []);
    }),
  );

  it.effect("lets a card write through only with health:cards", () =>
    Effect.gen(function* () {
      for (const scopes of ["health:read health:cards", "health:cards health:read mail:read"]) {
        assert.isTrue(Exit.isSuccess(yield* Effect.exit(inRequest(requireCardsScope, scopes))));
      }
      // Grants from before health:cards, another app's scope, a prefix, or no request at all.
      for (const scopes of ["health:read", "health:read mail:read", "health:card", "", undefined]) {
        const exit = yield* Effect.exit(inRequest(requireCardsScope, scopes));
        assert.deepStrictEqual(
          exit,
          Exit.fail(new HealthToolError({ message: missingCardsScopeMessage })),
          String(scopes),
        );
      }
      const outside = yield* Effect.exit(requireCardsScope);
      assert.isTrue(Exit.isFailure(outside));
    }),
  );

  it("tells the agent how to get it", () => {
    assert.strictEqual(
      missingCardsScopeMessage,
      "This agent can read lil health but not change cards. To let it, connect it again and " +
        "allow it to manage cards.",
    );
  });
});
