import { Effect, Option } from "effect";
import { HttpServerRequest } from "effect/http";
import { HttpApiBuilder } from "effect/http-api";
import { Api } from "../Api.ts";
import { CurrentSession, Unauthorized } from "../auth/AuthApi.ts";
import { AgentGrants } from "../core/AgentGrants.ts";
import { Consents } from "../core/Consents.ts";
import { Deployment } from "../Deployment.ts";
import { UserStores } from "../store/UserStores.ts";
import {
  AgentAccessEntry,
  AgentAccessLog,
  agentAccessLogPageSize,
  AgentsConsent,
  ConnectedAgent,
  ConnectedAgents,
} from "./AgentsApi.ts";
import {
  agentHosts,
  type AgentResource,
  agentResources,
  resourceFor,
  resourceUrl,
} from "./Hosts.ts";
import { requestOrigin } from "./Requests.ts";

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
    const { environment } = yield* Deployment;
    /** The hosts agents use, as seen from the app's request. */
    const requestHosts = HttpServerRequest.HttpServerRequest.use((request) =>
      Effect.succeed(agentHosts(environment, requestOrigin(request))),
    );
    /**
     * Turn Off Agent Access for one app: its agents are revoked first, so if anything fails the
     * consent stands and the app asks again, rather than agents reading without it.
     */
    const turnOff = (key: AgentResource) =>
      Effect.gen(function* () {
        const { userId } = yield* CurrentSession;
        const hosts = yield* requestHosts;
        yield* grants.deleteForResource(userId, resourceUrl(hosts, key));
        yield* consents.withdraw(userId, agentResources[key].consent);
      }).pipe(Effect.orDie);
    return handlers
      .handle("connectedAgents", () =>
        Effect.gen(function* () {
          const { userId } = yield* CurrentSession;
          const hosts = yield* requestHosts;
          const found = yield* grants.listForUser(userId);
          return new ConnectedAgents({
            agents: found.map(
              (grant) =>
                new ConnectedAgent({
                  id: grant.id,
                  name: grant.clientName,
                  domain: grant.clientDomain,
                  redirectHost: grant.redirectHost,
                  resource: grant.resource,
                  app: Option.getOrNull(resourceFor(hosts, grant.resource)),
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
