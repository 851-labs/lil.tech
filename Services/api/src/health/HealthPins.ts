import { Column, defineEntity } from "../store/Entities.ts";

/**
 * A data type pinned to the Mac's Summary (851-2641), keyed by its HealthKit type identifier, as
 * the Swift `HealthCatalog` module names it. The Mac writes pins (`POST /v1/sync/mutations`), so
 * every Mac shows the same ones.
 */
export const HealthPin = defineEntity("health_pin", {
  clientWritable: true,
  id: /^HK[A-Za-z]{1,120}$/,
  fields: {
    /** Where it's shown: pins are sorted by position, lowest first. */
    position: Column.real,
  },
});
