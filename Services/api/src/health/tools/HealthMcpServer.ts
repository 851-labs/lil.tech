import { Clock, Effect, Exit, Option, Predicate, Schema, Semaphore } from "effect";
import { McpServer } from "effect/ai";
import { HttpServerRequest } from "effect/http";
import { agentClientHeader, agentGrantHeader } from "../../mcp/AgentHeaders.ts";
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
 * How long a tool call may have waited for its turn in a store (851-2887). One that waited longer
 * by the time its turn comes is refused with a tool error asking the agent to try again, rather
 * than run.
 *
 * Workers resets a store whose CPU time since its last incoming request passes 30 seconds, failing
 * every call in flight. Refusing calls that waited long keeps a burst of calls from adding up to
 * that: the calls that run start within about this of their request, which leaves room for the
 * longest ones (a few seconds on a year of a Watch wearer's data). A single call that takes 30
 * seconds would still be too long.
 */
export const healthMcpMaxWaitMs = 10_000;

/** Waits for the next JavaScript task, so the runtime can commit the store's writes and send answers. */
const nextTask = Effect.callback<void>((resume) => {
  const timer = setTimeout(() => resume(Effect.void), 0);
  return Effect.sync(() => clearTimeout(timer));
});

/**
 * Runs `effect` and tells how long it took, in milliseconds, reading the clock in the next
 * JavaScript task after it ends (851-2907).
 *
 * Workers freezes its clock while code runs, as a Spectre mitigation: `Date.now()` (and Effect's
 * clock on it) only moves at I/O and when a new task starts. A tool call reads the store's SQLite
 * synchronously, so a clock read as it ends gave its start, and every call logged 0. The next task
 * starts once the call's has ended, so it sees the time the call took (and the moment the runtime
 * took to end its task), not the time it waited for its turn.
 */
export const timedToNextTask = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
  Effect.gen(function* () {
    const started = yield* Clock.currentTimeMillis;
    const result = yield* effect;
    yield* nextTask;
    return { result, durationMs: (yield* Clock.currentTimeMillis) - started };
  });

/**
 * Runs a store's tool calls one at a time, each in a JavaScript task of its own, and refuses those
 * that waited longer than `maxWaitMs` (851-2887).
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
export const makeTurns = (maxWaitMs: number = healthMcpMaxWaitMs) =>
  Effect.gen(function* () {
    const semaphore = yield* Semaphore.make(1);
    return <A, E, R>(call: Effect.Effect<A, E, R>): Effect.Effect<A, E | HealthToolError, R> =>
      Effect.gen(function* () {
        const arrived = yield* Clock.currentTimeMillis;
        const turn = Effect.gen(function* () {
          const waited = (yield* Clock.currentTimeMillis) - arrived;
          if (waited > maxWaitMs) {
            yield* Effect.logWarning("Agent tool call refused: busy").pipe(
              Effect.annotateLogs({ waitedMs: waited }),
            );
            return yield* new HealthToolError({
              message:
                "lil health is busy answering other calls from your agents. " +
                "Try again in a few seconds, with fewer calls at once.",
            });
          }
          yield* nextTask;
          return yield* call;
        });
        return yield* semaphore.withPermit(turn);
      });
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
 * call is logged (`record`) before anything goes back, so nothing is read without a row. Workers
 * Logs get the tool, grant, duration and size only: the duration is the call's own, from its turn
 * to its row (`timedToNextTask`), without its wait.
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
      const agent = agentOf(yield* Effect.serviceOption(HttpServerRequest.HttpServerRequest));
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
        return { exit, bytes };
      });
      const logCall = Effect.gen(function* () {
        const {
          result: { exit, bytes },
          durationMs,
        } = yield* timedToNextTask(call);
        yield* Effect.logInfo("Agent tool call").pipe(Effect.annotateLogs({ durationMs, bytes }));
        return yield* exit;
      });
      return yield* logCall.pipe(
        turn,
        Effect.annotateLogs({ tool: tool.name, grant: agent.grantId }),
      );
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
    /** How long a call may wait for its turn (`healthMcpMaxWaitMs`), without `turns`. */
    readonly maxWaitMs?: number;
  },
) =>
  Effect.gen(function* () {
    const turns = options.turns ?? (yield* makeTurns(options.maxWaitMs));
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
