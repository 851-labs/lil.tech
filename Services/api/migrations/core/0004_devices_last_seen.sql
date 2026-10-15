-- The daily cleanup of signed-out devices (`src/core/DeviceCleanup.ts`) finds the longest-unseen
-- devices first.
CREATE INDEX devices_last_seen_at ON devices (last_seen_at);
