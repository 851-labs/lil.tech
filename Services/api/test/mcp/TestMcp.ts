import { Effect, type Scope } from "effect";
import { HttpServerRequest, HttpServerResponse } from "effect/http";
import { servedLikeFetch } from "../store/TestUserStores.ts";

// An MCP client's requests over Streamable HTTP, as Claude and other agents send them, for tests.

export const sessionlessProtocol = "2026-07-28";
export const sessionProtocol = "2025-11-25";

export interface McpResponse {
  readonly status: number;
  readonly headers: Headers;
  /** The JSON-RPC message, from a JSON body or the last event of an SSE stream. */
  readonly message: Record<string, unknown> | undefined;
}

/** A response's JSON-RPC message, whether it came as JSON or as server-sent events. */
const readMessage = async (response: Response) => {
  const text = await response.text();
  if (text === "") return undefined;
  if (response.headers.get("content-type")?.startsWith("text/event-stream")) {
    const events = text
      .split("\n")
      .filter((line) => line.startsWith("data: "))
      .map((line) => JSON.parse(line.slice("data: ".length)) as Record<string, unknown>);
    return events.at(-1);
  }
  return JSON.parse(text) as Record<string, unknown>;
};

/** Answers a request: the Worker's handler, or a store's MCP server (`viaStore`). */
export type Sender = (request: Request) => Promise<Response> | Effect.Effect<Response>;

/** A store's MCP server as a `Sender`, as the store's `fetch` serves it. */
export const viaStore =
  (
    server: Effect.Effect<
      HttpServerResponse.HttpServerResponse,
      never,
      HttpServerRequest.HttpServerRequest | Scope.Scope
    >,
  ): Sender =>
  (request) =>
    servedLikeFetch(server).pipe(
      Effect.map((response) => HttpServerResponse.toWeb(response)),
      Effect.provideService(
        HttpServerRequest.HttpServerRequest,
        HttpServerRequest.fromWeb(request),
      ),
    );

/** Sends a request to an MCP endpoint and reads its answer. */
export const postMcp = (
  send: Sender,
  url: string,
  body: unknown,
  headers: Record<string, string> = {},
  method = "POST",
) =>
  Effect.gen(function* () {
    const request = new Request(url, {
      method,
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        ...headers,
      },
      ...(method === "POST" ? { body: JSON.stringify(body) } : {}),
    });
    const sent = send(request);
    const response = Effect.isEffect(sent) ? yield* sent : yield* Effect.promise(() => sent);
    const message = yield* Effect.promise(() => readMessage(response));
    return { status: response.status, headers: response.headers, message } satisfies McpResponse;
  });

/** The metadata every `2026-07-28` request carries, in place of a session. */
const requestMeta = {
  "io.modelcontextprotocol/protocolVersion": sessionlessProtocol,
  "io.modelcontextprotocol/clientCapabilities": {},
  "io.modelcontextprotocol/clientInfo": { name: "test-agent", version: "1.0.0" },
};

let nextId = 1;

/** A `2026-07-28` request: no session, its version and method in headers and metadata. */
export const sessionless = (
  method: string,
  params: Record<string, unknown> = {},
): { readonly body: unknown; readonly headers: Record<string, string> } => ({
  body: { jsonrpc: "2.0", id: nextId++, method, params: { ...params, _meta: requestMeta } },
  headers: {
    "mcp-protocol-version": sessionlessProtocol,
    "mcp-method": method,
    ...(method === "tools/call" ? { "mcp-name": String(params["name"]) } : {}),
  },
});

/** A JSON-RPC request in a session (`2025-11-25` and before). */
export const inSession = (method: string, params: Record<string, unknown> = {}) => ({
  jsonrpc: "2.0",
  id: nextId++,
  method,
  params,
});

/** `initialize` for a session protocol. */
export const initialize = (protocolVersion = sessionProtocol) =>
  inSession("initialize", {
    protocolVersion,
    capabilities: {},
    clientInfo: { name: "test-agent", version: "1.0.0" },
  });

/** The `notifications/initialized` a client sends once initialized. */
export const initialized = { jsonrpc: "2.0", method: "notifications/initialized" };
