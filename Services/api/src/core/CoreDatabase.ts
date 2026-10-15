import * as Cloudflare from "alchemy/Cloudflare";
import { Layer } from "effect";
import { Connections } from "./Connections.ts";
import { Consents } from "./Consents.ts";
import { Devices } from "./Devices.ts";
import { Identities } from "./Identities.ts";
import { IdentityTokenUses } from "./IdentityTokenUses.ts";
import { Sessions } from "./Sessions.ts";
import { Users } from "./Users.ts";

/**
 * The shared D1 database for data that spans users and apps. Migrations in `migrations/core` are
 * applied in order on every deploy.
 */
export const CoreDatabase = Cloudflare.D1.Database("Core", {
  migrations: "./migrations/core",
});

/** The core repositories. Needs a `SqlClient` for the core database. */
export const CoreRepositories = Layer.mergeAll(
  Users.layer,
  Identities.layer,
  Devices.layer,
  Connections.layer,
  Sessions.layer,
  IdentityTokenUses.layer,
  Consents.layer,
);
