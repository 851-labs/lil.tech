import {
  Clock,
  Context,
  Duration,
  Effect,
  Exit,
  Layer,
  Option,
  Predicate,
  Scheduler,
  Schema,
  Scope,
} from "effect";
import { McpProtocol, McpServer } from "effect/ai";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { agentClientHeader, agentGrantHeader } from "../../mcp/AgentHeaders.ts";
import { agentResources } from "../../oauth/Hosts.ts";
import type { AgentAccess } from "../../store/AgentAccessLog.ts";
import type { AccountDeleted } from "../../store/Changes.ts";
import type { StoreSql } from "../../store/StoreSql.ts";
import { HealthToolError, type HealthToolHandlers, HealthToolkit } from "./HealthToolkit.ts";
import { storeHealthTools } from "./StoreHealthTools.ts";
import { findHealthType } from "./ToolTypes.ts";

// lil health's remote MCP server (851-2851, `docs/decisions/server.md`): the Health toolkit over
// Streamable HTTP, served by the user's store from its own database. The Worker checks the agent's
// token and rate limit first, then forwards the request with the grant in trusted headers
// (`src/mcp/McpRoutes.ts`).

/** Where the server is, on the MCP host and in the store's `fetch`. */
export const healthMcpPath = agentResources.health.path;

/** The largest answer a tool may give, as JSON. Over it, the call fails and asks for less. */
export const healthMcpResultCeiling = 256 * 1024;

/**
 * The protocols the server speaks: `2026-07-28`, which needs no session, and the two before it for
 * clients that haven't moved yet, whose sessions (`Mcp-Session-Id`) Effect keeps in memory. A
 * store evicted while idle forgets them, and the client starts a new one after a 404.
 */
export const healthMcpProtocols = [
  McpProtocol.v2026_07_28,
  McpProtocol.v2025_11_25,
  McpProtocol.v2025_06_18,
] as const;

/** How many rows an answer holds: the items of its top-level lists. */
const rowCount = (encoded: unknown) =>
  Predicate.isObject(encoded)
    ? Object.values(encoded).reduce<number>(
        (count, value) => count + (Array.isArray(value) ? value.length : 0),
        0,
      )
    : 0;

/**
 * What the log keeps of a call's arguments: the type (its catalog identifier, however the call
 * named it, or nothing for a type the catalog doesn't have), range and day, never other text.
 */
const askedFor = (params: object) => {
  const field = (name: string) =>
    Predicate.hasProperty(params, name) && typeof params[name] === "string" ? params[name] : null;
  const type = field("type");
  const known = type === null ? undefined : findHealthType(type);
  return {
    types: known === undefined ? null : [known.id],
    range: field("range"),
    date: field("date"),
  };
};

/** The agent the Worker forwarded the request for. */
const agentOf = (request: Option.Option<HttpServerRequest.HttpServerRequest>) => {
  const headers = Option.match(request, {
    onNone: () => ({}) as Record<string, string | undefined>,
    onSome: (request) => request.headers as Record<string, string | undefined>,
  });
  const client = headers[agentClientHeader];
  let clientName = "Unknown agent";
  try {
    if (client !== undefined) clientName = decodeURIComponent(client);
  } catch {
    // Only the Worker sets it, encoded.
  }
  return { grantId: headers[agentGrantHeader] ?? "unknown", clientName };
};

/**
 * Wraps a tool's handler: its answer is held to `ceiling` bytes, and the call is logged
 * (`record`) before anything goes back, so nothing is read without a row. Workers Logs get the
 * tool, grant, duration and size only.
 */
const logged =
  <P extends object, A>(
    tool: { readonly name: string; readonly successSchema: Schema.Top },
    run: (params: P) => Effect.Effect<A, HealthToolError>,
    record: (access: AgentAccess) => Effect.Effect<void, AccountDeleted>,
    ceiling: number,
  ) =>
  (params: P) =>
    Effect.gen(function* () {
      const agent = agentOf(yield* Effect.serviceOption(HttpServerRequest.HttpServerRequest));
      const started = yield* Clock.currentTimeMillis;
      let exit: Exit.Exit<A, HealthToolError> = yield* Effect.exit(run(params));
      let bytes = 0;
      let rows = 0;
      let outcome: AgentAccess["outcome"] = "error";
      // An answer that can't be encoded fails the call, but is still logged.
      const answer = exit;
      const encoded = Exit.isSuccess(answer)
        ? yield* Effect.exit(
            Effect.try(() => {
              const value = Schema.encodeUnknownSync(tool.successSchema as Schema.Codec<unknown>)(
                answer.value,
              );
              return { value, bytes: new TextEncoder().encode(JSON.stringify(value)).byteLength };
            }),
          )
        : undefined;
      if (encoded !== undefined && Exit.isFailure(encoded)) exit = Exit.die(encoded.cause);
      if (encoded !== undefined && Exit.isSuccess(encoded)) {
        bytes = encoded.value.bytes;
        if (bytes > ceiling) {
          outcome = "too_large";
          exit = Exit.fail(
            new HealthToolError({
              message:
                `The answer is larger than ${Math.round(ceiling / 1024)} KB. ` +
                "Ask for a shorter range or a smaller page.",
            }),
          );
        } else {
          outcome = "ok";
          rows = rowCount(encoded.value.value);
        }
      }
      yield* record({ ...agent, tool: tool.name, ...askedFor(params), outcome, rows }).pipe(
        Effect.catchTag("AccountDeleted", () =>
          Effect.fail(new HealthToolError({ message: "This lil account was deleted." })),
        ),
      );
      const finished = yield* Clock.currentTimeMillis;
      yield* Effect.logInfo("Agent tool call").pipe(
        Effect.annotateLogs({
          tool: tool.name,
          grant: agent.grantId,
          durationMs: finished - started,
          bytes,
        }),
      );
      return yield* exit;
    });

/**
 * Shared fibers in a Durable Object run on the sync scheduler, as Effect advises for Workers, so
 * no request's timers hold up another's work.
 */
const syncScheduler = new Scheduler.MixedScheduler("sync");

/**
 * The server for one store, as an HTTP handler for `POST`, `DELETE` and the rest at
 * `healthMcpPath`. It's built on the first request and lives as long as the store's object, which
 * is where legacy sessions are kept. Requests with an `Origin` get 403: no browser origins are
 * allowed, as the transport requires.
 */
export const makeHealthMcpServer = (options: {
  readonly sql: StoreSql;
  readonly record: (access: AgentAccess) => Effect.Effect<void, AccountDeleted>;
  /** The largest answer, as JSON (`healthMcpResultCeiling`, but tests make it smaller). */
  readonly resultCeiling?: number;
}) =>
  Effect.gen(function* () {
    const { sql, record, resultCeiling = healthMcpResultCeiling } = options;
    const handlers = storeHealthTools(sql);
    const tools = HealthToolkit.tools;
    // Every tool's handler, logged and held to the ceiling.
    const loggedHandlers: HealthToolHandlers = {
      summary: logged(tools.summary, handlers.summary, record, resultCeiling),
      list_types: logged(tools.list_types, handlers.list_types, record, resultCeiling),
      metric: logged(tools.metric, handlers.metric, record, resultCeiling),
      samples: logged(tools.samples, handlers.samples, record, resultCeiling),
      workouts: logged(tools.workouts, handlers.workouts, record, resultCeiling),
      sleep: logged(tools.sleep, handlers.sleep, record, resultCeiling),
      medications: logged(tools.medications, handlers.medications, record, resultCeiling),
      health_details: logged(tools.health_details, handlers.health_details, record, resultCeiling),
      search: logged(tools.search, handlers.search, record, resultCeiling),
      sync_status: logged(tools.sync_status, handlers.sync_status, record, resultCeiling),
    };
    const layer = McpServer.toolkit(HealthToolkit).pipe(
      Layer.provide(HealthToolkit.toLayer(loggedHandlers)),
      Layer.provideMerge(
        McpServer.layerHttp({
          name: "lil health",
          version: "1.0.0",
          instructions:
            "Read-only access to the user's lil health data: Apple Health, synced from their " +
            "iPhone. Times are in UTC unless a call gives a timeZone.",
          path: healthMcpPath,
          protocols: healthMcpProtocols,
          // Ends a legacy session on request. Only the user's own agents reach this store.
          allowSessionTermination: true,
          // The tools never change, so there's nothing to subscribe to, and no stream is kept open.
          allowSubscriptions: false,
        }),
      ),
      Layer.provide(Layer.succeed(Scheduler.Scheduler, syncScheduler)),
    );
    // Never closed: the server lives until the object is evicted.
    const scope = yield* Scope.make();
    // Built on its own, with its own router, outside the request that first needs it: its fibers
    // outlive that request, and mustn't keep its services. Only the clock is the store's.
    const clock = yield* Clock.Clock;
    const build = Layer.buildWithMemoMap(
      Layer.provideMerge(layer, HttpRouter.layer),
      Layer.makeMemoMapUnsafe(),
      scope,
    ).pipe(
      Effect.map((context) => Context.get(context, HttpRouter.HttpRouter).asHttpEffect()),
      Effect.provideContext(Context.make(Clock.Clock, clock)),
      Effect.orDie,
    );
    // Kept once built; a build that failed is tried again on the next request.
    const handler = yield* Effect.cachedWithTTL(build, (exit) =>
      Exit.isSuccess(exit) ? Duration.infinity : Duration.zero,
    );
    return handler.pipe(
      Effect.flatMap((handle) => handle),
      Effect.catch((error) =>
        // Only a path the server doesn't have.
        Predicate.isTagged(error, "HttpServerError")
          ? Effect.succeed(HttpServerResponse.empty({ status: 404 }))
          : Effect.die(error),
      ),
      Effect.provideService(Scheduler.Scheduler, syncScheduler),
    );
  });
