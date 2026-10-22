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
import {
  Headers,
  HttpEffect,
  HttpRouter,
  HttpServerRequest,
  HttpServerResponse,
} from "effect/http";

// An MCP server in a user's store (851-2851, `docs/decisions/server.md`): each app's own, and the
// combined one (851-2900). The Worker checks the agent's token and rate limit first, then forwards
// the request with the grant in trusted headers (`McpRoutes.ts`).

/**
 * The protocols the servers speak: `2026-07-28`, which needs no session, and the two before it for
 * clients that haven't moved yet, whose sessions (`Mcp-Session-Id`) Effect keeps in memory. The
 * store keeps them too (`StoreMcpSessions`), so they outlive its object (851-2947).
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
 * A server's sessions as the store keeps them (`src/store/McpSessions.ts`): what each agent sent
 * to start its session, by the session's ID, so a server that's new (the store's object was taken
 * out of memory while idle, which Workers does after about 10 seconds) can start it again.
 */
export interface StoreMcpSessions {
  /** Keeps session `id`, with `initialize`'s params as its agent sent them, as JSON. */
  readonly save: (id: string, initialize: string) => Effect.Effect<void>;
  /** What the agent sent to start session `id`, if it's kept. */
  readonly find: (id: string) => Effect.Effect<string | undefined>;
  /** Marks session `id` used now, so it's kept longer. */
  readonly touch: (id: string) => Effect.Effect<void>;
  /** Forgets session `id`. */
  readonly remove: (id: string) => Effect.Effect<void>;
}

const sessionHeader = "mcp-session-id";
const protocolVersionHeader = "mcp-protocol-version";

/** The headers of a JSON-RPC message of ours to the server, as agents send them. */
const jsonRpcHeaders = {
  "content-type": "application/json",
  accept: "application/json, text/event-stream",
};

/** `initialize`'s params, if `body` is an `initialize` request. */
const initializeParams = (body: string): unknown => {
  try {
    const message: unknown = JSON.parse(body);
    return Predicate.isObject(message) && message["method"] === "initialize"
      ? (message["params"] ?? null)
      : undefined;
  } catch {
    return undefined;
  }
};

/** How starting a kept session again went. */
type StartedAgain =
  /** It goes on in Effect's session `id`. */
  | { readonly _tag: "Started"; readonly id: string }
  /** It isn't kept, or can't be started again: the agent gets a 404 and starts a new one. */
  | { readonly _tag: "Gone" }
  /** The server failed: the agent gets its `response`, and the next request tries again. */
  | { readonly _tag: "Failed"; readonly response: HttpServerResponse.HttpServerResponse };

/**
 * `serve`, with its sessions kept in `sessions` as well as in memory (851-2947). A new session is
 * saved with what its agent sent to start it. A request in a session this server doesn't have in
 * memory starts it again from what was saved, as the agent first did, and goes on in it: Effect
 * gives the new session an ID of its own, so the agent's is mapped to it. Ending a session forgets
 * it. A session that was never saved, or another server's, still gets a 404.
 */
const keepingSessions = (serve: StoreMcpHandler, sessions: StoreMcpSessions): StoreMcpHandler => {
  /**
   * Serves a message of ours to the server at `url`, with the changes the server makes to its
   * response just before sending it (a new session's headers), which Effect keeps by request.
   */
  const serveOurs = (url: string, headers: Headers.Headers, body: string) =>
    Effect.gen(function* () {
      let served: HttpServerResponse.HttpServerResponse | undefined;
      yield* HttpEffect.toHandled(serve, (_, response) =>
        Effect.sync(() => {
          served = response;
        }),
      );
      return served ?? HttpServerResponse.empty({ status: 500 });
    }).pipe(
      Effect.provideService(
        HttpServerRequest.HttpServerRequest,
        HttpServerRequest.fromWeb(
          new Request(new URL(url, "http://store"), {
            method: "POST",
            headers: Headers.setAll(Headers.remove(headers, "content-length"), jsonRpcHeaders),
            body,
          }),
        ),
      ),
    );

  /**
   * How each session this server has in memory goes on, by the ID its agent knows: in Effect's
   * session of the same ID, or of another once it was started again (once, by the first request
   * that needed it).
   */
  const inMemory = new Map<string, Effect.Effect<StartedAgain>>();

  /** Starts session `id` again from what its agent sent, in a new session of Effect's. */
  const startAgain = (request: HttpServerRequest.HttpServerRequest, id: string) =>
    Effect.gen(function* () {
      const initialize = yield* sessions.find(id);
      if (initialize === undefined) return { _tag: "Gone" } as const;
      const headers = Headers.removeMany(request.headers, [sessionHeader, protocolVersionHeader]);
      const started = yield* serveOurs(
        request.url,
        headers,
        `{"jsonrpc":"2.0","id":0,"method":"initialize","params":${initialize}}`,
      );
      if (started.status >= 500) return { _tag: "Failed", response: started } as const;
      const restarted = started.headers[sessionHeader];
      const version = started.headers[protocolVersionHeader];
      if (started.status !== 200 || restarted === undefined || version === undefined) {
        // The server refused it (its protocol is gone, say): the agent starts a new session.
        yield* sessions.remove(id);
        return { _tag: "Gone" } as const;
      }
      const notified = yield* serveOurs(
        request.url,
        Headers.setAll(headers, { [sessionHeader]: restarted, [protocolVersionHeader]: version }),
        `{"jsonrpc":"2.0","method":"notifications/initialized"}`,
      );
      if (notified.status >= 500) return { _tag: "Failed", response: notified } as const;
      yield* sessions.touch(id);
      return { _tag: "Started", id: restarted } as const;
    });

  /** Keeps the session `response` starts, if `request` is an `initialize`. */
  const keepStarted = (
    request: HttpServerRequest.HttpServerRequest,
    response: HttpServerResponse.HttpServerResponse,
  ) => {
    const started = response.headers[sessionHeader];
    if (response.status !== 200 || started === undefined) return Effect.succeed(response);
    // The server has read the body already, which the request keeps.
    return request.text.pipe(
      Effect.flatMap((body) => {
        const params = initializeParams(body);
        return params === undefined ? Effect.void : sessions.save(started, JSON.stringify(params));
      }),
      Effect.tap(() =>
        Effect.sync(() => inMemory.set(started, Effect.succeed({ _tag: "Started", id: started }))),
      ),
      // Not kept, the session still works while the store is in memory, as before.
      Effect.catchCause((cause) => Effect.logWarning("Keeping an MCP session failed", cause)),
      Effect.as(response),
    );
  };

  return Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest;
    const id = request.headers[sessionHeader];
    if (id === undefined) {
      const response = yield* serve;
      // A new session's ID is only on its response once the server's own handler has run, so
      // it's kept from a handler that runs after it.
      if (request.method === "POST") {
        yield* HttpEffect.appendPreResponseHandler((_, sent) => keepStarted(request, sent));
      }
      return response;
    }
    let known = inMemory.get(id);
    if (known === undefined) {
      if (request.method === "DELETE") {
        // Ended without starting it again first, if it's kept; else the server's 404.
        if ((yield* sessions.find(id)) === undefined) return yield* serve;
        yield* sessions.remove(id);
        return HttpServerResponse.empty({ status: 204 });
      }
      known = yield* Effect.cached(startAgain(request, id));
      inMemory.set(id, known);
    }
    const attempt = known;
    const current = yield* attempt.pipe(
      Effect.onExit((exit) =>
        Effect.sync(() => {
          // Only a session that goes on stays in memory; else the next request asks again.
          const goesOn = Exit.isSuccess(exit) && exit.value._tag === "Started";
          if (!goesOn && inMemory.get(id) === attempt) inMemory.delete(id);
        }),
      ),
    );
    if (current._tag === "Failed") return current.response;
    // Not kept, or not this server's: the server's 404, so the agent starts a new session.
    if (current._tag === "Gone") return yield* serve;
    const response = yield* current.id === id
      ? serve
      : serve.pipe(
          Effect.provideService(
            HttpServerRequest.HttpServerRequest,
            request.modify({ headers: Headers.set(request.headers, sessionHeader, current.id) }),
          ),
        );
    if (request.method === "DELETE" && response.status === 204) {
      inMemory.delete(id);
      yield* sessions.remove(id);
    }
    return response;
  });
};

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
  /** Where the server's sessions are kept, beside its memory. */
  readonly sessions: StoreMcpSessions;
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
    const serve = handler.pipe(
      Effect.flatMap((handle) => handle),
      Effect.catch((error) =>
        // Only a path the server doesn't have.
        Predicate.isTagged(error, "HttpServerError")
          ? Effect.succeed(HttpServerResponse.empty({ status: 404 }))
          : Effect.die(error),
      ),
    );
    return keepingSessions(serve, options.sessions).pipe(
      Effect.provideService(Scheduler.Scheduler, syncScheduler),
    );
  });
