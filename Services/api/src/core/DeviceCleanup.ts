import { Clock, Effect } from "effect";
import { UserStores } from "../store/UserStores.ts";
import { Devices } from "./Devices.ts";

// Devices that stopped without signing out (the app deleted, the phone wiped, refresh tokens
// expired) are retired by a daily job, as signing out does (`docs/SYNC.md`).

/** How long a device without a live session must also have been unseen before it's retired. */
export const signedOutGrace = 24 * 60 * 60 * 1000;

/** The most devices one run retires; the next day's run continues. */
export const cleanupBatchSize = 500;

/**
 * Retires devices with no live session that haven't been seen for `signedOutGrace`: each is
 * retired in its user's store, then its row (and its dead sessions) deleted. A device whose store
 * couldn't be reached keeps its row and is tried again on the next run. Returns how many it retired.
 */
export const retireSignedOutDevices = Effect.fn("retireSignedOutDevices")(function* (
  limit = cleanupBatchSize,
) {
  const devices = yield* Devices;
  const stores = yield* UserStores;
  const now = yield* Clock.currentTimeMillis;
  const stale = yield* devices.listSignedOut(now, now - signedOutGrace, limit);
  let retired = 0;
  for (const device of stale) {
    const ok = yield* stores
      .forUser(device.userId)
      .retireDevice(device.id)
      .pipe(
        Effect.as(true),
        Effect.catchCause((cause) =>
          Effect.logWarning(`Retiring device ${device.id} failed`, cause).pipe(Effect.as(false)),
        ),
      );
    if (ok) {
      yield* devices.delete(device.id);
      retired += 1;
    }
  }
  return retired;
});
