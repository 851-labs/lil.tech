import {
  Clock,
  Context,
  Duration,
  Effect,
  Exit,
  Layer,
  Predicate,
  Scheduler,
  type Scope,
  Scope as Scopes,
} from "effect";
import { McpProtocol, McpServer } from "effect/ai";
import { HttpRouter, type HttpServerRequest, HttpServerResponse } from "effect/http";

// An MCP server in a user's store (851-2851, `docs/decisions/server.md`): each app's own, and the
// combined one (851-2900). The Worker checks the agent's token and rate limit first, then forwards
// the request with the grant in trusted headers (`McpRoutes.ts`).

/**
 * The protocols the servers speak: `2026-07-28`, which needs no session, and the two before it for
 * clients that haven't moved yet, whose sessions (`Mcp-Session-Id`) Effect keeps in memory. A
 * store evicted while idle forgets them, and the client starts a new one after a 404.
 */
export const storeMcpProtocols = [
  McpProtocol.v2026_07_28,
  McpProtocol.v2025_11_25,
  McpProtocol.v2025_06_18,
] as const;

/** A server's handler, as the store's `fetch` serves it. */
export type StoreMcpHandler = Effect.Effect<
  HttpServerResponse.HttpServerResponse,
  never,
  HttpServerRequest.HttpServerRequest | Scope.Scope
>;

/** An app's tools, ready to register with a server: its own, or the combined one. */
export interface StoreMcpApp {
  /** What the app's server tells agents when they connect. */
  readonly instructions: string;
  /** Registers the app's tools (and any resources) with the server in context. */
  readonly register: Effect.Effect<void, never, McpServer.McpServer>;
}

/**
 * Shared fibers in a Durable Object run on the sync scheduler, as Effect advises for Workers, so
 * no request's timers hold up another's work.
 */
const syncScheduler = new Scheduler.MixedScheduler("sync");

/**
 * A server for one store, as an HTTP handler for `POST`, `DELETE` and the rest at `path`. It's
 * built on the first request and lives as long as the store's object, which is where legacy
 * sessions are kept. Requests with an `Origin` get 403: no browser origins are allowed, as the
 * transport requires.
 */
export const serveStoreMcp = (options: {
  readonly name: string;
  readonly instructions: string;
  readonly path: HttpRouter.PathInput;
  /** Registers the server's tools. */
  readonly register: Effect.Effect<void, never, McpServer.McpServer>;
}): Effect.Effect<StoreMcpHandler> =>
  Effect.gen(function* () {
    // The tools register with the server the transport serves.
    const layer = Layer.effectDiscard(options.register).pipe(
      Layer.provideMerge(
        McpServer.layerHttp({
          name: options.name,
          version: "1.0.0",
          instructions: options.instructions,
          path: options.path,
          protocols: storeMcpProtocols,
          // Ends a legacy session on request. Only the user's own agents reach this store.
          allowSessionTermination: true,
          // The tools never change, so there's nothing to subscribe to, and no stream is kept open.
          allowSubscriptions: false,
        }),
      ),
      Layer.provide(Layer.succeed(Scheduler.Scheduler, syncScheduler)),
    );
    // Never closed: the server lives until the object is evicted.
    const scope = yield* Scopes.make();
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
