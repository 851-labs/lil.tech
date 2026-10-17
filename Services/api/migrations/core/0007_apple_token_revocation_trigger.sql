-- Every deleted Sign in with Apple identity's token is queued for revoking (851-2612), in the same
-- statement as the deletion (including the cascade from deleting its user), so none is lost
-- between the two. Times are milliseconds.
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
