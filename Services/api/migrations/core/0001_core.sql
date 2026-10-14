-- The shared "core" database: data that spans users and apps. Each user's own data (health, and
-- later mail and calendar) lives in their per-user store, not here. Times are Unix milliseconds.

CREATE TABLE users (
  id TEXT PRIMARY KEY, -- usr_…
  display_name TEXT,
  created_at INTEGER NOT NULL
);

-- Ways to sign in (Sign in with Apple, Sign in with Google). Separate from connections: signing in
-- with Google proves who you are; connecting Gmail grants access to data.
CREATE TABLE identities (
  id TEXT PRIMARY KEY, -- idt_…
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  provider TEXT NOT NULL, -- apple, google
  subject TEXT NOT NULL, -- the provider's stable user ID
  email TEXT,
  email_verified INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE (provider, subject)
);
CREATE INDEX identities_user_id ON identities (user_id);

-- App installs that sign in: an iPhone running lil health, a Mac running lil health, and so on.
CREATE TABLE devices (
  id TEXT PRIMARY KEY, -- dev_…
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  app TEXT NOT NULL, -- health-ios, health-mac, …
  platform TEXT NOT NULL, -- ios, macos
  name TEXT,
  push_token TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);
CREATE INDEX devices_user_id ON devices (user_id);

-- Refresh-token sessions, one per signed-in device. Tokens rotate on every use; a family groups a
-- session's rotations so reusing an old token can revoke all of them.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY, -- ses_…
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
  family_id TEXT NOT NULL,
  refresh_token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX sessions_user_id ON sessions (user_id);
CREATE INDEX sessions_family_id ON sessions (family_id);

-- Data sources a user has connected: Apple Health (an iPhone's HealthKit store) now, later Gmail,
-- Microsoft, IMAP and CalDAV accounts. Credentials are encrypted before they're stored.
CREATE TABLE connections (
  id TEXT PRIMARY KEY, -- con_…
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  kind TEXT NOT NULL, -- apple_health, google, microsoft, imap, caldav
  account_ref TEXT NOT NULL, -- the account at the provider, e.g. an email address or device ID
  display_name TEXT,
  scopes TEXT NOT NULL DEFAULT '[]', -- JSON array of granted scopes
  credentials TEXT, -- encrypted; null when the source needs none (Apple Health)
  status TEXT NOT NULL DEFAULT 'active', -- active, needs_reauth, revoked
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (user_id, kind, account_ref)
);
CREATE INDEX connections_user_id ON connections (user_id);
