import { Effect, Exit, Option, Predicate, Schema, Semaphore } from "effect";
import { McpServer } from "effect/ai";
import { HttpEffect, HttpServerRequest, HttpServerResponse } from "effect/http";
import {
  agentAnswerBytesHeader,
  agentClientHeader,
  agentGrantHeader,
  agentToolHeader,
} from "../../mcp/AgentHeaders.ts";
import { serveStoreMcp, type StoreMcpApp } from "../../mcp/StoreMcpServer.ts";
import { agentResources } from "../../oauth/Hosts.ts";
import type { AgentAccess } from "../../store/AgentAccessLog.ts";
import type { AccountDeleted } from "../../store/Changes.ts";
import type { StoreSql } from "../../store/StoreSql.ts";
import { HealthToolError, type HealthToolHandlers, HealthToolkit } from "./HealthToolkit.ts";
import { type HealthToolImplementations, storeHealthTools } from "./StoreHealthTools.ts";
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
 * How many tool calls a store's queue holds, the one running included (851-2887, 851-2941). A
 * call that comes when it's full is refused at once with a tool error asking the agent to try
 * again, rather than queued.
 *
 * Workers resets a store whose CPU time since its last incoming request passes 30 seconds, failing
 * every call in flight. Each call's request is an incoming request, so once the last one of a
 * burst has come, the most the store has left to do is the calls in its queue: at most this many
 * of the heaviest calls (about 0.7 seconds each on a year of a Watch wearer's data, 851-2906),
 * about 11 seconds. A single call that takes 30 seconds would still be too long.
 *
 * It counts calls rather than timing their wait, because a store can't time it: its clock only
 * moves at I/O, not while it computes, so it lags behind a burst's work (851-2907, 851-2941).
 */
export const healthMcpMaxQueuedCalls = 16;

/** Waits for the next JavaScript task, so the runtime can commit the store's writes and send answers. */
const nextTask = Effect.callback<void>((resume) => {
  const timer = setTimeout(() => resume(Effect.void), 0);
  return Effect.sync(() => clearTimeout(timer));
});

/**
 * Runs a store's tool calls one at a time, each in a JavaScript task of its own, and refuses those
 * that come when `maxQueued` calls are already in its queue (851-2887, 851-2941).
 *
 * A store runs on one thread and its SQLite reads are synchronous, so calls never ran in parallel.
 * But the server's fibers run on the sync scheduler, which continues in microtasks, so concurrent
 * calls ran back to back in one task, with nothing else in between: the runtime only commits a
 * store's writes (each call's access log row) and sends its answers once a task ends, and it
 * resets a store when a storage operation waits about 30 seconds. On prod, eight calls at once
 * took that long together, and every one failed with a 500. A call that gets its turn waits for
 * the next task before it starts, so the call before it commits its row and sends its answer
 * first.
 */
export const makeTurns = (maxQueued: number = healthMcpMaxQueuedCalls) =>
  Effect.gen(function* () {
    const semaphore = yield* Semaphore.make(1);
    let queued = 0;
    const enter = Effect.suspend(() => {
      if (queued < maxQueued) {
        queued += 1;
        return Effect.void;
      }
      return Effect.logWarning("Agent tool call refused: busy").pipe(
        Effect.annotateLogs({ queued }),
        Effect.andThen(
          Effect.fail(
            new HealthToolError({
              message:
                "lil health is busy answering other calls from your agents. " +
                "Try again in a few seconds, with fewer calls at once.",
            }),
          ),
        ),
      );
    });
    const leave = Effect.sync(() => {
      queued -= 1;
    });
    return <A, E, R>(call: Effect.Effect<A, E, R>): Effect.Effect<A, E | HealthToolError, R> =>
      Effect.acquireUseRelease(
        enter,
        () => semaphore.withPermit(Effect.andThen(nextTask, call)),
        () => leave,
      );
  });

/**
 * A store's queue of tool calls (`makeTurns`): the one its every MCP server shares, lil health's
 * own and the combined one, as they share its one thread.
 */
export type Turns = Effect.Success<ReturnType<typeof makeTurns>>;

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
 * Wraps a tool's handler: it runs in its `turn`, its answer is held to `ceiling` bytes, and the
 * call is logged (`record`) before anything goes back, so nothing is read without a row.
 *
 * Workers Logs get the tool, grant, duration and size only, from the Worker (`McpRoutes.ts`,
 * 851-2907). The store's clock doesn't move while a call runs, so the store puts the tool and the
 * answer's size in its response's headers, and the Worker, whose clock moved while it waited for
 * the store, adds the duration.
 */
const logged =
  <P extends object, A>(
    tool: { readonly name: string; readonly successSchema: Schema.Top },
    run: (params: P) => Effect.Effect<A, HealthToolError>,
    record: (access: AgentAccess) => Effect.Effect<void, AccountDeleted>,
    ceiling: number,
    turn: <B, E>(call: Effect.Effect<B, E>) => Effect.Effect<B, E | HealthToolError>,
  ) =>
  (params: P) =>
    Effect.gen(function* () {
      const request = yield* Effect.serviceOption(HttpServerRequest.HttpServerRequest);
      const agent = agentOf(request);
      const call = Effect.gen(function* () {
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
        if (Option.isSome(request)) {
          HttpEffect.appendPreResponseHandlerUnsafe(request.value, (_, response) =>
            Effect.succeed(
              HttpServerResponse.setHeaders(response, {
                [agentToolHeader]: tool.name,
                [agentAnswerBytesHeader]: String(bytes),
              }),
            ),
          );
        }
        return yield* exit;
      });
      return yield* call.pipe(turn, Effect.annotateLogs({ tool: tool.name, grant: agent.grantId }));
    });

/** What lil health's server tells agents when they connect, and the combined server under its name. */
export const healthMcpInstructions =
  "Read-only access to the user's lil health data: Apple Health, synced from their " +
  "iPhone. Times are in UTC unless a call gives a timeZone.";

/**
 * lil health's tools for a store's MCP servers: each one's handler logged, held to the ceiling
 * and run in the store's `turns`.
 */
export const healthMcpApp = (options: {
  readonly sql: StoreSql;
  readonly record: (access: AgentAccess) => Effect.Effect<void, AccountDeleted>;
  readonly turns: Turns;
  /** The largest answer, as JSON (`healthMcpResultCeiling`, but tests make it smaller). */
  readonly resultCeiling?: number;
  /** Each tool's implementation (`storeHealthTools`, but tests slow some down). */
  readonly handlers?: HealthToolImplementations;
}): StoreMcpApp => {
  const { record, turns, resultCeiling = healthMcpResultCeiling } = options;
  const handlers = options.handlers ?? storeHealthTools(options.sql);
  const tools = HealthToolkit.tools;
  const wrap = <P extends object, A>(
    tool: { readonly name: string; readonly successSchema: Schema.Top },
    run: (params: P) => Effect.Effect<A, HealthToolError>,
  ) => logged(tool, run, record, resultCeiling, turns);
  const loggedHandlers: HealthToolHandlers = {
    summary: wrap(tools.summary, handlers.summary),
    list_types: wrap(tools.list_types, handlers.list_types),
    metric: wrap(tools.metric, handlers.metric),
    samples: wrap(tools.samples, handlers.samples),
    workouts: wrap(tools.workouts, handlers.workouts),
    sleep: wrap(tools.sleep, handlers.sleep),
    medications: wrap(tools.medications, handlers.medications),
    health_details: wrap(tools.health_details, handlers.health_details),
    search: wrap(tools.search, handlers.search),
    sync_status: wrap(tools.sync_status, handlers.sync_status),
  };
  return {
    instructions: healthMcpInstructions,
    register: McpServer.registerToolkit(HealthToolkit).pipe(
      Effect.provide(HealthToolkit.toLayer(loggedHandlers)),
    ),
  };
};

/**
 * lil health's own server for one store, at `healthMcpPath` (`serveStoreMcp`). The store passes
 * its `turns`, which the combined server shares; tests get a queue of their own.
 */
export const makeHealthMcpServer = (
  options: Omit<Parameters<typeof healthMcpApp>[0], "turns"> & {
    readonly turns?: Turns;
    /** How many calls its queue holds (`healthMcpMaxQueuedCalls`), without `turns`. */
    readonly maxQueued?: number;
  },
) =>
  Effect.gen(function* () {
    const turns = options.turns ?? (yield* makeTurns(options.maxQueued));
    return yield* serveHealthMcp(healthMcpApp({ ...options, turns }));
  });

/** lil health's own server, serving `app` (`healthMcpApp`) at `healthMcpPath`. */
export const serveHealthMcp = (app: StoreMcpApp) =>
  serveStoreMcp({
    name: "lil health",
    instructions: app.instructions,
    path: healthMcpPath,
    register: app.register,
  });
