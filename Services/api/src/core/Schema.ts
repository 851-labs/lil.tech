import { sql } from "drizzle-orm";
import {
  type AnySQLiteColumn,
  foreignKey,
  index,
  integer,
  sqliteTable,
  text,
  unique,
  uniqueIndex,
} from "drizzle-orm/sqlite-core";

// The shared "core" database: data that spans users and apps. Each user's own data (health, and
// later mail and calendar) lives in their per-user store, not here. Times are Unix milliseconds.
//
// Migrations are generated from this file into `migrations/core` by `scripts/format`, and applied
// by Alchemy on deploy. Anything Drizzle can't express (the trigger on `identities`) is SQL added
// to a generated migration by hand.

export const users = sqliteTable("users", {
  id: text().primaryKey(), // usr_…
  displayName: text("display_name"),
  createdAt: integer("created_at").notNull(),
  // How much the user's store holds (its SQLite size in bytes), as last measured, for finding the
  // largest users with `scripts/largest-users.sql`. Updated after each health batch is applied;
  // null until the first one.
  storageBytes: integer("storage_bytes"),
  storageMeasuredAt: integer("storage_measured_at"),
});

// Ways to sign in (Sign in with Apple, Sign in with Google). Separate from connections: signing in
// with Google proves who you are; connecting Gmail grants access to data.
//
// The baseline migration adds a trigger to this table by hand (queueing Apple tokens for revoking
// when an identity is deleted). A change here that makes drizzle-kit rebuild the table drops the
// trigger, so the generated migration must create it again; a test checks it's there.
export const identities = sqliteTable(
  "identities",
  {
    id: text().primaryKey(), // idt_…
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    provider: text().notNull(), // apple, google
    subject: text().notNull(), // the provider's stable user ID
    email: text(),
    emailVerified: integer("email_verified", { mode: "boolean" })
      .notNull()
      .default(sql`0`),
    createdAt: integer("created_at").notNull(),
    // Apple's refresh token, encrypted (`src/auth/AppleTokens.ts`), so deleting the account can
    // revoke it, as Apple requires (851-2612), and the client ID it was issued to.
    appleRefreshToken: text("apple_refresh_token"),
    appleClientId: text("apple_client_id"),
  },
  (table) => [
    unique("identities_provider_subject").on(table.provider, table.subject),
    index("identities_user_id").on(table.userId),
  ],
);

// App installs that sign in: an iPhone running lil health, a Mac running lil health, and so on.
export const devices = sqliteTable(
  "devices",
  {
    id: text().primaryKey(), // dev_…
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    app: text().notNull(), // health-ios, health-mac, …
    platform: text().notNull(), // ios, macos
    name: text(),
    pushToken: text("push_token"),
    createdAt: integer("created_at").notNull(),
    lastSeenAt: integer("last_seen_at").notNull(),
  },
  (table) => [
    // Lets sessions require that a device belongs to the session's user.
    unique("devices_id_user_id").on(table.id, table.userId),
    index("devices_user_id").on(table.userId),
    // The daily cleanup of signed-out devices (`DeviceCleanup.ts`) finds the longest-unseen first.
    index("devices_last_seen_at").on(table.lastSeenAt),
  ],
);

// Refresh-token sessions, one per signed-in device. Tokens rotate on every use; a family groups a
// session's rotations so reusing an old token can revoke all of them.
export const sessions = sqliteTable(
  "sessions",
  {
    id: text().primaryKey(), // ses_…
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    deviceId: text("device_id").notNull(),
    familyId: text("family_id").notNull(),
    refreshTokenHash: text("refresh_token_hash").notNull().unique(),
    createdAt: integer("created_at").notNull(),
    expiresAt: integer("expires_at").notNull(),
    revokedAt: integer("revoked_at"),
  },
  (table) => [
    // The device must belong to the same user.
    foreignKey({
      columns: [table.deviceId, table.userId],
      foreignColumns: [devices.id, devices.userId],
    }).onDelete("cascade"),
    index("sessions_user_id").on(table.userId),
    index("sessions_device_id").on(table.deviceId, table.userId),
    index("sessions_family_id").on(table.familyId),
  ],
);

// Data sources a user has connected: Apple Health (an iPhone's HealthKit store) now, later Gmail,
// Microsoft, IMAP and CalDAV accounts. Credentials are encrypted before they're stored.
export const connections = sqliteTable(
  "connections",
  {
    id: text().primaryKey(), // con_…
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    kind: text().notNull(), // apple_health, google, microsoft, imap, caldav
    accountRef: text("account_ref").notNull(), // the account at the provider
    displayName: text("display_name"),
    // JSON array of granted scopes.
    scopes: text({ mode: "json" })
      .$type<ReadonlyArray<string>>()
      .notNull()
      .default(sql`'[]'`),
    credentials: text(), // encrypted; null when the source needs none (Apple Health)
    status: text().notNull().default("active"), // active, needs_reauth, revoked
    createdAt: integer("created_at").notNull(),
    updatedAt: integer("updated_at").notNull(),
  },
  // Also serves lookups by user_id, as its leading column.
  (table) => [
    unique("connections_user_kind_account").on(table.userId, table.kind, table.accountRef),
  ],
);

// Provider ID tokens (Sign in with Apple, Google) already exchanged for a session, so a captured
// sign-in request can't be replayed. Rows are kept until the token expires.
export const identityTokenUses = sqliteTable(
  "identity_token_uses",
  {
    tokenHash: text("token_hash").primaryKey(), // SHA-256 hex of the ID token
    expiresAt: integer("expires_at").notNull(),
  },
  (table) => [index("identity_token_uses_expires_at").on(table.expiresAt)],
);

// Consents and their withdrawals (`Consents.ts`), kept as proof of consent. They're deleted with
// the user, along with the rest of their data.
export const consents = sqliteTable(
  "consents",
  {
    id: integer().primaryKey({ autoIncrement: true }),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    type: text().notNull(), // e.g. health
    policyVersion: text("policy_version").notNull(), // the privacy policy's effective date
    grantedAt: integer("granted_at").notNull(),
    withdrawnAt: integer("withdrawn_at"),
  },
  (table) => [
    index("consents_user_type").on(table.userId, table.type, table.grantedAt),
    // One active consent per user, type and policy version, however requests race.
    uniqueIndex("consents_active")
      .on(table.userId, table.type, table.policyVersion)
      .where(sql`${table.withdrawnAt} IS NULL`),
  ],
);

// Tokens of deleted Sign in with Apple identities, waiting to be revoked: right after the
// deletion, and by the daily job if that fails. Keyed by the identity, which is gone. A trigger
// on `identities` queues them (in the baseline migration).
export const appleTokenRevocations = sqliteTable(
  "apple_token_revocations",
  {
    id: text().primaryKey(),
    refreshToken: text("refresh_token").notNull(), // encrypted, as in identities
    clientId: text("client_id").notNull(),
    attempts: integer().notNull(),
    nextAttemptAt: integer("next_attempt_at").notNull(),
    createdAt: integer("created_at").notNull(),
  },
  (table) => [index("apple_token_revocations_next").on(table.nextAttemptAt)],
);

// OAuth clients of the agents' authorization server (`docs/decisions/accounts.md`, Agents): each
// one either a Client ID Metadata Document, cached here (`cimd`, whose `client_id` is the
// document's URL), or registered dynamically (`dcr`, `cli_…`). Public clients only, so there are
// no secrets. No logos: the consent page loads no remote images.
export const oauthClients = sqliteTable("oauth_clients", {
  id: text().primaryKey(), // ocl_…
  clientId: text("client_id").notNull().unique(),
  kind: text().notNull(), // cimd, dcr
  name: text(), // client_name; a dynamically registered client may have none
  clientUri: text("client_uri"),
  redirectUris: text("redirect_uris", { mode: "json" }).$type<ReadonlyArray<string>>().notNull(),
  applicationType: text("application_type").notNull(), // web, native
  // When a cached metadata document must be fetched again. Null for registered clients.
  expiresAt: integer("expires_at"),
  createdAt: integer("created_at").notNull(),
  // When the client was last resolved for an authorization or token request. Null until then.
  lastUsedAt: integer("last_used_at"),
});

// An agent's request to connect (`/oauth/authorize`), kept 10 minutes, and once the user allows
// it on the consent page, its authorization code (`docs/decisions/accounts.md`, Agents). The code
// is single-use: redeeming it sets `used_at` and the grant it made, so redeeming it again can
// delete that grant.
export const agentAuthorizations = sqliteTable(
  "agent_authorizations",
  {
    id: text().primaryKey(), // aau_…
    clientId: text("client_id")
      .notNull()
      .references(() => oauthClients.clientId, { onDelete: "cascade" }),
    redirectUri: text("redirect_uri").notNull(),
    state: text(),
    codeChallenge: text("code_challenge").notNull(), // S256 only
    // JSON array of the scopes asked for.
    scopes: text({ mode: "json" }).$type<ReadonlyArray<string>>().notNull(),
    resource: text().notNull(), // the app's MCP server, e.g. https://mcp.lil.tech/health
    // SHA-256 hex of the `__Host-` cookie that binds the request to its browser.
    browserHash: text("browser_hash").notNull(),
    createdAt: integer("created_at").notNull(),
    expiresAt: integer("expires_at").notNull(),
    // Set when the user starts signing in with Apple or Google (851-2850): which, the SHA-256 hex
    // of the `state` sent to it, and the nonce whose SHA-256 its ID token must carry. Starting
    // again replaces them. The provider's answer clears them, so it works once, and records whose
    // account it was and the SHA-256 hex of a ticket for the browser that brought it, which
    // finishes the sign-in with the request's cookie.
    signInProvider: text("sign_in_provider"), // apple, google
    signInStateHash: text("sign_in_state_hash"),
    signInNonce: text("sign_in_nonce"),
    signInUserId: text("sign_in_user_id").references(() => users.id, { onDelete: "cascade" }),
    signInTicketHash: text("sign_in_ticket_hash"),
    // Set when the user signs in on the authorization page.
    userId: text("user_id").references(() => users.id, { onDelete: "cascade" }),
    // Set when they allow it.
    grantedScopes: text("granted_scopes", { mode: "json" }).$type<ReadonlyArray<string>>(),
    codeHash: text("code_hash").unique(), // SHA-256 hex of the authorization code
    codeExpiresAt: integer("code_expires_at"),
    // Set when the code is redeemed.
    usedAt: integer("used_at"),
    grantId: text("grant_id"), // the grant the code made
  },
  (table) => [
    index("agent_authorizations_expires_at").on(table.expiresAt),
    index("agent_authorizations_client_id").on(table.clientId),
    index("agent_authorizations_user_id").on(table.userId),
  ],
);

// Connected agents: one per authorization a user allowed, for one app's MCP server (`resource`).
// Revoking deletes the row, and its tokens with it.
export const agentGrants = sqliteTable(
  "agent_grants",
  {
    id: text().primaryKey(), // agr_…
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    clientId: text("client_id")
      .notNull()
      .references(() => oauthClients.clientId, { onDelete: "cascade" }),
    // The client as the consent page showed it: its name, its metadata document's domain (null
    // for a registered client) and the host it redirected to.
    clientName: text("client_name"),
    clientDomain: text("client_domain"),
    redirectHost: text("redirect_host").notNull(),
    scopes: text({ mode: "json" }).$type<ReadonlyArray<string>>().notNull(),
    resource: text().notNull(),
    createdAt: integer("created_at").notNull(),
    // Any request to the MCP server, recorded at most every 5 minutes: the connection time until
    // then, or until the first tool call.
    lastUsedAt: integer("last_used_at").notNull(),
    // The first tool call, recorded exactly (851-2872). Null until the agent reads anything.
    firstUsedAt: integer("first_used_at"),
  },
  (table) => [
    index("agent_grants_user_id").on(table.userId),
    index("agent_grants_client_id").on(table.clientId),
  ],
);

// Agents' opaque tokens, stored only as SHA-256 hashes: access tokens (`lma_…`, 1 hour) and
// rotating refresh tokens (`lmr_…`, 90 days). Each rotation's pair is a refresh token, which
// `replaces` the one presented, and an access token that names it (`refresh_token_hash`).
// `used_at` is when the token was first used; on a refresh token, when its pair was, which ends
// the grace of the token it replaced.
export const agentTokens = sqliteTable(
  "agent_tokens",
  {
    tokenHash: text("token_hash").primaryKey(),
    grantId: text("grant_id")
      .notNull()
      .references(() => agentGrants.id, { onDelete: "cascade" }),
    kind: text().notNull(), // access, refresh
    // A refresh token's predecessor, which it replaced. Null for a code exchange's.
    replaces: text(),
    // An access token's refresh token, issued with it. Deleting that deletes this.
    refreshTokenHash: text("refresh_token_hash").references(
      (): AnySQLiteColumn => agentTokens.tokenHash,
      { onDelete: "cascade" },
    ),
    expiresAt: integer("expires_at").notNull(),
    usedAt: integer("used_at"),
  },
  (table) => [
    index("agent_tokens_grant_id").on(table.grantId),
    index("agent_tokens_replaces").on(table.replaces),
    index("agent_tokens_refresh_token_hash").on(table.refreshTokenHash),
    index("agent_tokens_expires_at").on(table.expiresAt),
  ],
);
