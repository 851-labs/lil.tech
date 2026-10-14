import { Context } from "effect";
import type { UserId } from "../core/Ids.ts";
import type { UserStoreMethods } from "./UserStore.ts";

/** The Durable Object name of a user's store (`docs/SYNC.md`). */
export const userStoreName = (userId: UserId) => `user:${userId}`;

/** Each user's store, called over Durable Object RPC. */
export class UserStores extends Context.Service<
  UserStores,
  { readonly forUser: (userId: UserId) => UserStoreMethods }
>()("lil/api/store/UserStores") {
  /** Stores addressed by name in a Durable Object namespace. */
  static readonly fromNamespace = (namespace: {
    readonly getByName: (name: string) => UserStoreMethods;
  }) => UserStores.of({ forUser: (userId) => namespace.getByName(userStoreName(userId)) });
}
