import { sql } from "drizzle-orm";
import {
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
