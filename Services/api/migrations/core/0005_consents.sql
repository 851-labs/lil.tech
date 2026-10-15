-- Consents and their withdrawals (`src/core/Consents.ts`), kept as proof of consent. A user's go
-- when the user is deleted, with the rest of their data.
CREATE TABLE consents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  type TEXT NOT NULL, -- e.g. health
  policy_version TEXT NOT NULL, -- the privacy policy's effective date, e.g. 2026-10-15
  granted_at INTEGER NOT NULL,
  withdrawn_at INTEGER
);

CREATE INDEX consents_user_type ON consents (user_id, type, granted_at);
