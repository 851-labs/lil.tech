-- How much each user's store holds (its SQLite size in bytes), as last measured, for finding the
-- largest users with `scripts/largest-users.sql`. Updated after each health batch is applied; NULL
-- until the first one. No index: that query is run rarely, by hand, and a scan is cheap.
ALTER TABLE users ADD COLUMN storage_bytes INTEGER;
ALTER TABLE users ADD COLUMN storage_measured_at INTEGER;
