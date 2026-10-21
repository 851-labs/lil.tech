import { Context, Effect, Predicate, Schema } from "effect";
import { type HttpServerRequest, HttpServerResponse } from "effect/http";
import type { UserId } from "../core/Ids.ts";
import type { UserStoreMethods } from "./UserStore.ts";

/** The Durable Object name of a user's store (`docs/SYNC.md`). */
export const userStoreName = (userId: UserId) => `user:${userId}`;

/**
 * A call to a store failed in a way Cloudflare marks as transient, e.g. the object was restarting
 * during a deploy or was overloaded. Retrying later can succeed.
 */
export class UserStoreUnavailable extends Schema.TaggedError<UserStoreUnavailable>()(
  "UserStoreUnavailable",
  { message: Schema.String },
  { httpApiStatus: 503 },
) {}

/** Cloudflare sets `retryable` or `overloaded` on Durable Object errors worth retrying. */
const isTransient = (cause: unknown) =>
  (Predicate.hasProperty(cause, "retryable") && cause.retryable === true) ||
  (Predicate.hasProperty(cause, "overloaded") && cause.overloaded === true);

/**
 * Cloudflare sets `durableObjectReset` on requests in flight when a store was reset (e.g. a
 * storage operation timed out). The next request starts it again (851-2887). Only forwarded
 * requests treat it as transient: they read (MCP) or connect (live notices), while an RPC call that
 * writes may have committed before the reset.
 */
const isReset = (cause: unknown) =>
  Predicate.hasProperty(cause, "durableObjectReset") && cause.durableObjectReset === true;

/** A store's methods as callers see them: every call can also fail with `UserStoreUnavailable`. */
export type UserStoreClient = {
  readonly [K in keyof UserStoreMethods]: UserStoreMethods[K] extends (
    ...args: infer Args
  ) => Effect.Effect<infer A, infer E, infer R>
    ? (...args: Args) => Effect.Effect<A, E | UserStoreUnavailable, R>
    : never;
};

/** Each user's store, called over Durable Object RPC. */
export class UserStores extends Context.Service<
  UserStores,
  {
    readonly forUser: (userId: UserId) => UserStoreClient;
    /** Hands a live notice connection (a WebSocket upgrade) to the user's store. */
    readonly live: (
      userId: UserId,
      request: HttpServerRequest.HttpServerRequest,
    ) => Effect.Effect<HttpServerResponse.HttpServerResponse>;
    /**
     * Hands a request to one of the user's MCP servers (`src/mcp/McpRoutes.ts`), whose path is
     * the app's. The caller has checked the agent and set its trusted headers.
     */
    readonly mcp: (
      userId: UserId,
      request: HttpServerRequest.HttpServerRequest,
    ) => Effect.Effect<HttpServerResponse.HttpServerResponse>;
  }
>()("lil/api/store/UserStores") {
  /**
   * Stores addressed by name in a Durable Object namespace. Alchemy's stubs are typed like the
   * store's own methods, but fail with `RpcCallError` when the call itself fails. That becomes
   * `UserStoreUnavailable` if Cloudflare marks the failure `retryable` or `overloaded`, and a
   * defect (a 500) otherwise, such as a bug that throws inside the store, which retrying won't fix.
   * A forwarded request (MCP, live notices) also gets a 503 when the store was reset.
   */
  static readonly fromNamespace = (namespace: {
    readonly getByName: (name: string) => UserStoreMethods & {
      readonly fetch: (
        request: HttpServerRequest.HttpServerRequest,
      ) => Effect.Effect<HttpServerResponse.HttpServerResponse, unknown>;
    };
  }) => {
    // A transient failure is a 503, like the store's other calls; anything else a 500.
    const forward = (userId: UserId, request: HttpServerRequest.HttpServerRequest) =>
      namespace
        .getByName(userStoreName(userId))
        .fetch(request)
        .pipe(
          Effect.catch((error) => {
            const cause = Predicate.isTagged(error, "RpcCallError")
              ? (error as { readonly cause?: unknown }).cause
              : error;
            return isTransient(cause) || isReset(cause)
              ? Effect.succeed(
                  HttpServerResponse.jsonUnsafe(
                    { _tag: "UserStoreUnavailable", message: String(cause) },
                    { status: 503 },
                  ),
                )
              : Effect.die(error);
          }),
        );
    return UserStores.of({
      live: forward,
      mcp: forward,
      forUser: (userId) => {
        const stub = namespace.getByName(userStoreName(userId));
        return new Proxy({} as UserStoreClient, {
          get: (_, method) => {
            const call = Reflect.get(stub, method) as (
              ...args: Array<unknown>
            ) => Effect.Effect<unknown, unknown>;
            return (...args: Array<unknown>) =>
              call(...args).pipe(
                Effect.catchIf(
                  (error) => Predicate.isTagged(error, "RpcCallError"),
                  (error) => {
                    const cause = (error as { readonly cause?: unknown }).cause;
                    return isTransient(cause)
                      ? Effect.fail(
                          new UserStoreUnavailable({
                            message: `Store call ${String(method)} failed: ${String(cause)}`,
                          }),
                        )
                      : Effect.die(cause);
                  },
                ),
              );
          },
        });
      },
    });
  };
}
