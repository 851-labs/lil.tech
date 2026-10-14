-- Provider ID tokens (Sign in with Apple, Google) already exchanged for a session, so a captured
-- sign-in request can't be replayed. Rows are kept until the token expires.
CREATE TABLE identity_token_uses (
  token_hash TEXT PRIMARY KEY, -- SHA-256 hex of the ID token
  expires_at INTEGER NOT NULL
);

CREATE INDEX identity_token_uses_expires_at ON identity_token_uses (expires_at);
