import { applyMutations } from "./ChangeLog.ts";
import type { Mutation } from "./Changes.ts";
import type { Entity } from "./Entities.ts";
import type { StoreSql } from "./StoreSql.ts";

// Devices that signed out for good. Their device-scoped records (`docs/sync/protocol.md`) are
// deleted a chunk at a time by the store's alarm, through the change log, so clients delete them
// too. A device-scoped entity with many rows needs an index on `device`, like `health_statistic`'s.

/** Why the store refuses a retired device's records. */
export const deviceSignedOut = "The device signed out";

/** Records deleted per alarm, in one transaction each. */
export const retireChunkSize = 2000;

/** The time between retirement alarms, so deleting a large device doesn't monopolize the store. */
export const retireStepInterval = 5_000;

/** Marks a device retired, if it isn't already. Retired devices are kept for good. */
export const markRetired = (sql: StoreSql, device: string, at: number) => {
  sql.exec(
    "INSERT OR IGNORE INTO retired_devices (device, retired_at, cleared_at) VALUES (?, ?, NULL)",
    device,
    at,
  );
};

/** Whether a retired device still has records to delete. */
export const hasRetiringDevices = (sql: StoreSql) =>
  sql.exec("SELECT 1 FROM retired_devices WHERE cleared_at IS NULL LIMIT 1").length > 0;

/** Which of `devices` are retired. */
export const retiredAmong = (sql: StoreSql, devices: ReadonlySet<string>): ReadonlySet<string> =>
  devices.size === 0
    ? new Set()
    : new Set(
        sql
          .exec(
            `SELECT device FROM retired_devices WHERE device IN (${[...devices].map(() => "?").join(", ")})`,
            ...devices,
          )
          .map((row) => row["device"] as string),
      );

/**
 * Deletes up to `limit` of retired devices' records, oldest retirement first, and marks a device
 * cleared once it has none left. Returns how many were deleted.
 */
export const retireStep = (
  sql: StoreSql,
  registry: ReadonlyArray<Entity>,
  at: number,
  limit = retireChunkSize,
) => {
  const entitiesByName = new Map(registry.map((entity) => [entity.name, entity]));
  // The device's own record (`self`, e.g. its statistics status) goes first, so clients stop
  // treating it as a source before its other records are gone.
  const scoped = registry
    .filter((entity) => entity.deviceScoped !== undefined)
    .sort(
      (a, b) =>
        Number(b.deviceScoped?.id.test("self") ?? false) -
        Number(a.deviceScoped?.id.test("self") ?? false),
    );
  let deleted = 0;
  const devices = sql.exec(
    "SELECT device FROM retired_devices WHERE cleared_at IS NULL ORDER BY retired_at, device",
  );
  for (const row of devices) {
    const device = row["device"] as string;
    let found = 0;
    for (const entity of scoped) {
      if (deleted === limit) return deleted;
      const ids = sql
        .exec(`SELECT id FROM "${entity.name}" WHERE device = ? LIMIT ?`, device, limit - deleted)
        .map((idRow) => idRow["id"] as string);
      if (ids.length === 0) continue;
      const mutations = ids.map((id): Mutation => ({ entity: entity.name, op: "delete", id }));
      applyMutations(sql, entitiesByName, mutations, at);
      found += ids.length;
      deleted += ids.length;
    }
    if (found === 0) {
      sql.exec("UPDATE retired_devices SET cleared_at = ? WHERE device = ?", at, device);
    }
  }
  return deleted;
};
