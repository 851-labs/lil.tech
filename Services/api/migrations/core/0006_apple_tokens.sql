-- Apple's refresh token for a Sign in with Apple identity, encrypted (`src/auth/AppleTokens.ts`), so
-- deleting the account can revoke it, as Apple requires (851-2612). `apple_client_id` is what it
-- was issued to: the iPhone's App ID or the Mac's Services ID.
ALTER TABLE identities ADD COLUMN apple_refresh_token TEXT;
ALTER TABLE identities ADD COLUMN apple_client_id TEXT;

-- Revocations that failed when an account was deleted, tried again by the daily job until they
-- work or run out of attempts. Not tied to the user, who's gone.
CREATE TABLE apple_token_revocations (
  id TEXT PRIMARY KEY,
  refresh_token TEXT NOT NULL, -- encrypted, as in identities
  client_id TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX apple_token_revocations_next ON apple_token_revocations (next_attempt_at);
