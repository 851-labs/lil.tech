import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { latestSampleStart, statisticsDevices, statisticsSource } from "./HealthQueries.ts";
import type { HealthToolkit } from "./HealthToolkit.ts";
import { localTime, toolTimeZone } from "./ToolTime.ts";

type SyncStatusResult = (typeof HealthToolkit.tools.sync_status.successSchema)["Type"];

/**
 * The `sync_status` tool from the user's store: when the newest sample that has started starts,
 * and each iPhone that reports statistics, most recently reported first, saying which one totals
 * come from.
 */
export const healthSyncStatus = Effect.fn("healthSyncStatus")(function* (
  sql: StoreSql,
  input: { readonly timeZone?: string | undefined },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const devices = statisticsDevices(sql);
  const source = statisticsSource(devices, now);
  const latest = latestSampleStart(sql, now);
  const result: SyncStatusResult = {
    timeZone: name,
    latestSample: latest === null ? null : localTime(latest, zone),
    iPhones: devices.map((device) => ({
      device: device.device,
      pairedWithWatch: device.pairedWithWatch,
      lastReported: localTime(device.reportedAt, zone),
      statisticsSource: device.device === source,
    })),
  };
  return result;
});
