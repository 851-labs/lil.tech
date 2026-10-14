import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { migrate } from "./Migrations.ts";
import { fromDurableObjectStorage, type StoreSql } from "./StoreSql.ts";

/**
 * A store's RPC methods over its database. Every method first brings the schema up to date, so a
 * store is migrated the first time it's used after a deploy, and again after `deleteAll`.
 */
export const makeUserStore = (sql: StoreSql) => {
  let schemaVersion: number | undefined;
  const ready = () => (schemaVersion ??= migrate(sql));

  return {
    schemaVersion: () => Effect.sync(ready),
    /** Deletes everything in the store, for account deletion. */
    deleteAll: () =>
      Effect.promise(async () => {
        schemaVersion = undefined;
        await sql.deleteAll();
        // A request that interleaved at the `await` may have migrated the old database.
        schemaVersion = undefined;
      }),
  };
};

export type UserStoreMethods = ReturnType<typeof makeUserStore>;

/** One user's data, in a SQLite-backed Durable Object. Reach it through `UserStores`. */
export class UserStore extends Cloudflare.DurableObject<UserStore>()(
  "UserStore",
  Effect.gen(function* () {
    const state = yield* Cloudflare.DurableObjectState;
    return Effect.sync(() => makeUserStore(fromDurableObjectStorage(state.raw.storage)));
  }),
) {}
