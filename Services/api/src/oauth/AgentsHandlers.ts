import { Clock, Effect, Option } from "effect";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "../Api.ts";
import { CurrentSession, Unauthorized } from "../auth/AuthApi.ts";
import { AgentGrants } from "../core/AgentGrants.ts";
import { Consents } from "../core/Consents.ts";
import type { UserId } from "../core/Ids.ts";
import { UserStores } from "../store/UserStores.ts";
import {
  AgentAccessEntry,
  AgentAccessLog,
  agentAccessLogPageSize,
  AgentsConsent,
  ConnectedAgent,
  ConnectedAgents,
} from "./AgentsApi.ts";
import { type AgentResource, agentResources, appOfResource } from "./Hosts.ts";

// The apps' endpoints for connected agents (851-2852, `AgentsApi.ts`). They exist in every
// environment, prod included, so the apps can ship before agents can connect there (851-2855):
// until then there's nothing to list.

export const AgentsHandlers = HttpApiBuilder.group(
  Api,
  "agents",
  Effect.fn(function* (handlers) {
    const grants = yield* AgentGrants;
    const consents = yield* Consents;
    const stores = yield* UserStores;
    /** Revokes the user's agents of one app, and its requests to connect one. */
    const revokeApp = (userId: UserId, key: AgentResource) =>
      grants.resourcesForUser(userId).pipe(
        Effect.map((resources) =>
          resources.filter((resource) => Option.contains(appOfResource(resource), key)),
        ),
        Effect.flatMap((resources) => grants.deleteForResources(userId, resources)),
      );
    /**
     * Turn Off Agent Access for one app. Its agents are revoked first, so if that fails the consent
     * stands and the app asks again, rather than agents reading without it. Then again once the
     * consent is withdrawn, for an agent the user allowed in a browser meanwhile: one allowed after
     * that gives consent again, as a new connection.
     */
    const turnOff = (key: AgentResource) =>
      Effect.gen(function* () {
        const { userId } = yield* CurrentSession;
        yield* revokeApp(userId, key);
        yield* consents.withdraw(userId, agentResources[key].consent);
        yield* revokeApp(userId, key);
      }).pipe(Effect.orDie);
    return handlers
      .handle("connectedAgents", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          const found = yield* grants.listForUser(userId, yield* Clock.currentTimeMillis);
          return new ConnectedAgents({
            agents: found.map(
              (grant) =>
                new ConnectedAgent({
                  id: grant.id,
                  name: grant.clientName,
                  domain: grant.clientDomain,
                  redirectHost: grant.redirectHost,
                  resource: grant.resource,
                  app: Option.getOrNull(appOfResource(grant.resource)),
                  connectedAt: grant.createdAt,
                  lastUsedAt: grant.lastUsedAt,
                }),
            ),
          });
        }).pipe(Effect.orDie),
      )
      .handle("agentAccessLog", ({ query }) =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          // One more than a page, to tell whether there's another.
          const rows = yield* stores
            .forUser(userId)
            .agentAccessLog(query.before ?? null, agentAccessLogPageSize + 1);
          const page = rows.slice(0, agentAccessLogPageSize);
          return new AgentAccessLog({
            entries: page.map(
              (row) =>
                new AgentAccessEntry({
                  id: row.id,
                  at: row.at,
                  agentId: row.grantId,
                  agentName: row.clientName,
                  tool: row.tool,
                  types: row.types,
                  range: row.range,
                  date: row.date,
                  outcome: row.outcome,
                  rows: row.rows,
                }),
            ),
            nextBefore: rows.length > agentAccessLogPageSize ? (page.at(-1)?.id ?? null) : null,
          });
        }).pipe(
          // The access token outlived its account (deleted within the last 15 minutes).
          Effect.catchTag("AccountDeleted", () =>
            Effect.fail(new Unauthorized({ message: "The user no longer exists" })),
          ),
        ),
      )
      .handle("revokeAgent", ({ params }) =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          yield* grants.deleteForUser(userId, params.id);
        }).pipe(Effect.orDie),
      )
      .handle("healthAgentsConsent", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          const given = yield* consents.current(userId, agentResources.health.consent);
          return new AgentsConsent({ given: Option.getOrNull(given) });
        }).pipe(Effect.orDie),
      )
      .handle("withdrawHealthAgentsConsent", () => turnOff("health"));
  }),
);
