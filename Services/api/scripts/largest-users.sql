-- The users with the largest stores, as last measured. Run it in the D1 console for a stage's
-- core database (the stack's `coreDatabase` output). It shows only IDs and sizes.
SELECT id, storage_bytes, datetime(storage_measured_at / 1000, 'unixepoch') AS measured
FROM users
WHERE storage_bytes IS NOT NULL
ORDER BY storage_bytes DESC
LIMIT 50;
