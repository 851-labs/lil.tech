import { Column, defineEntity } from "../store/Entities.ts";

/**
 * A data type pinned to the Mac's Summary (851-2641), keyed by its HealthKit type identifier, as
 * the Swift `HealthCatalog` module names it. The Mac wrote pins (`POST /v1/sync/mutations`), so
 * every Mac showed the same ones.
 *
 * Retired (851-2990): nothing reads pins any more, and today's Mac neither writes nor syncs them.
 * The entity stays, so Macs from before (0.3.0) still push and pull theirs without errors, and
 * exports still include any that exist. Its table stays too, since store migrations only add.
 */
export const HealthPin = defineEntity("health_pin", {
  clientWritable: true,
  id: /^HK[A-Za-z0-9]{1,120}$/,
  fields: {
    /** Where it's shown: pins are sorted by position, lowest first. */
    position: Column.real,
  },
});
