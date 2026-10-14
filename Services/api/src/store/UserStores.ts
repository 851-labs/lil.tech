import { Context, Effect, Predicate, Schema } from "effect";
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
  { readonly forUser: (userId: UserId) => UserStoreClient }
>()("lil/api/store/UserStores") {
  /**
   * Stores addressed by name in a Durable Object namespace. Alchemy's stubs are typed like the
   * store's own methods, but fail with `RpcCallError` when the call itself fails. That becomes
   * `UserStoreUnavailable` if Cloudflare marks the failure `retryable` or `overloaded`, and a
   * defect (a 500) otherwise, such as a bug that throws inside the store, which retrying won't fix.
   */
  static readonly fromNamespace = (namespace: {
    readonly getByName: (name: string) => UserStoreMethods;
  }) =>
    UserStores.of({
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
}
