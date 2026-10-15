-- How much each user's store holds, as last measured (its SQLite size in bytes), for finding the
-- largest users. Updated whenever the user uploads a health batch; NULL until the first one.
ALTER TABLE users ADD COLUMN storage_bytes INTEGER;
ALTER TABLE users ADD COLUMN storage_measured_at INTEGER;

CREATE INDEX users_storage_bytes ON users (storage_bytes);
