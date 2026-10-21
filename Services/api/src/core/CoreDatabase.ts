import * as Cloudflare from "alchemy/Cloudflare";
import * as SQL from "alchemy/SQL/D1";
import { Layer } from "effect";
import { AppleTokenRevocations } from "./AppleTokenRevocations.ts";
import { Connections } from "./Connections.ts";
import { Consents } from "./Consents.ts";
import { CoreDb } from "./CoreDb.ts";
import { Devices } from "./Devices.ts";
import { Identities } from "./Identities.ts";
import { IdentityTokenUses } from "./IdentityTokenUses.ts";
import { OAuthClients } from "./OAuthClients.ts";
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

/**
 * The core database from a D1 binding (`Cloudflare.D1.QueryDatabase(CoreDatabase)`): `CoreDb`,
 * Drizzle over `@effect/sql-d1`'s client.
 */
export const coreDatabase = <E, R>(d1: SQL.D1DatabaseSource<E, R>) =>
  CoreDb.d1.pipe(Layer.provide(SQL.D1Layer(d1)));

/** The core repositories. Needs `CoreDb`. */
export const CoreRepositories = Layer.mergeAll(
  Users.layer,
  Identities.layer,
  Devices.layer,
  Connections.layer,
  Sessions.layer,
  IdentityTokenUses.layer,
  Consents.layer,
  AppleTokenRevocations.layer,
  OAuthClients.layer,
);
