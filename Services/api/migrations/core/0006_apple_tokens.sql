-- Apple's refresh token for a Sign in with Apple identity, encrypted (`src/auth/AppleTokens.ts`), so
-- deleting the account can revoke it, as Apple requires (851-2612). `apple_client_id` is what it
-- was issued to: the iPhone's App ID or the Mac's Services ID.
ALTER TABLE identities ADD COLUMN apple_refresh_token TEXT;
ALTER TABLE identities ADD COLUMN apple_client_id TEXT;

-- Tokens of deleted identities, waiting to be revoked: right after the deletion, and by the daily
-- job if that fails, until it works or runs out of attempts. Keyed by the identity, which is gone.
CREATE TABLE apple_token_revocations (
  id TEXT PRIMARY KEY,
  refresh_token TEXT NOT NULL, -- encrypted, as in identities
  client_id TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE INDEX apple_token_revocations_next ON apple_token_revocations (next_attempt_at);

-- Every deleted identity's token is queued, in the same statement as the deletion (including the
-- cascade from deleting its user), so none is lost between the two. Times are milliseconds.
CREATE TRIGGER identities_queue_apple_token_revocation
BEFORE DELETE ON identities
WHEN OLD.apple_refresh_token IS NOT NULL AND OLD.apple_client_id IS NOT NULL
BEGIN
  INSERT INTO apple_token_revocations
    (id, refresh_token, client_id, attempts, next_attempt_at, created_at)
  VALUES (
    OLD.id, OLD.apple_refresh_token, OLD.apple_client_id, 0,
    CAST(strftime('%s', 'now') AS INTEGER) * 1000, CAST(strftime('%s', 'now') AS INTEGER) * 1000
  )
  ON CONFLICT (id) DO UPDATE SET
    refresh_token = excluded.refresh_token, client_id = excluded.client_id, attempts = 0;
END;
