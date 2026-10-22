import { Clock, Effect } from "effect";
import type { DeviceId, UserId } from "./Ids.ts";
import { UserStores } from "../store/UserStores.ts";
import { Devices } from "./Devices.ts";

// Retiring devices that signed out for good (`docs/sync/protocol.md`): on sign-out, and daily for
// those that stopped without signing out (the app deleted, the phone wiped, refresh tokens
// expired).

/** How long a device without a live session must also have been unseen before it's retired. */
export const signedOutGrace = 24 * 60 * 60 * 1000;

/**
 * The most devices one daily run retires; the next day's run continues. Each costs a store call
 * and a D1 delete, which keeps a run well under the Workers subrequest limit.
 */
export const cleanupBatchSize = 200;

/**
 * Retires a device in its user's store, then deletes its row with `deleteRow` (which may decline,
 * e.g. if it signed in again meanwhile). If the store can't be reached, the row stays, so a later
 * run tries again. A deleted account's store is already empty, so that counts as retired.
 * Answers whether the row was deleted.
 */
export const retireDevice = Effect.fn("retireDevice")(function* <E>(
  userId: UserId,
  deviceId: DeviceId,
  deleteRow: Effect.Effect<boolean, E>,
) {
  const stores = yield* UserStores;
  const retired = yield* stores
    .forUser(userId)
    .retireDevice(deviceId)
    .pipe(
      Effect.as(true),
      Effect.catchTag("AccountDeleted", () => Effect.succeed(true)),
      Effect.catchCause((cause) =>
        Effect.logWarning(`Retiring device ${deviceId} failed`, cause).pipe(Effect.as(false)),
      ),
    );
  return retired ? yield* deleteRow : false;
});

/**
 * Retires devices with no live session that haven't been seen for `signedOutGrace`, a few at a
 * time. One device's failure doesn't stop the others. Returns how many it retired.
 */
export const retireSignedOutDevices = Effect.fn("retireSignedOutDevices")(function* (
  limit = cleanupBatchSize,
) {
  const devices = yield* Devices;
  const now = yield* Clock.currentTimeMillis;
  const stale = yield* devices.listSignedOut(now, now - signedOutGrace, limit);
  const results = yield* Effect.forEach(
    stale,
    (device) =>
      retireDevice(device.userId, device.id, devices.deleteIfNoLiveSession(device.id, now)).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning(`Deleting device ${device.id} failed`, cause).pipe(Effect.as(false)),
        ),
      ),
    { concurrency: 10 },
  );
  return results.filter(Boolean).length;
});
