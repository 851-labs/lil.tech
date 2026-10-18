import * as Cloudflare from "alchemy/Cloudflare";
import { Layer } from "effect";
import { AppleTokenRevocations } from "./AppleTokenRevocations.ts";
import { Connections } from "./Connections.ts";
import { Consents } from "./Consents.ts";
import { Devices } from "./Devices.ts";
import { Identities } from "./Identities.ts";
import { IdentityTokenUses } from "./IdentityTokenUses.ts";
import { Sessions } from "./Sessions.ts";
import { Users } from "./Users.ts";

/**
 * The shared D1 database for data that spans users and apps. Its schema is `Schema.ts`; the
 * migrations drizzle-kit generates from it (`migrations/core`) are applied in order on every
 * deploy.
 *
 * The ID was "Core" until 851-2686, which started over on Drizzle: a new ID makes Alchemy create a
 * fresh database from the new baseline and delete the old one, in every stage.
 */
export const CoreDatabase = Cloudflare.D1.Database("Core2", {
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
  AppleTokenRevocations.layer,
);
