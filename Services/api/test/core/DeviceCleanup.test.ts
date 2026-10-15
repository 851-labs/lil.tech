import { assert, describe, it } from "@effect/vitest";
import { Effect, Layer, Option } from "effect";
import { TestClock } from "effect/testing";
import { Auth } from "../../src/auth/Auth.ts";
import { retireSignedOutDevices } from "../../src/core/DeviceCleanup.ts";
import { Devices } from "../../src/core/Devices.ts";
import { Users } from "../../src/core/Users.ts";
import { TestAuth } from "../auth/TestAuth.ts";
import { TestStores, TestUserStores } from "../store/TestUserStores.ts";

const day = 24 * 60 * 60 * 1000;

describe("retireSignedOutDevices", () => {
  it.effect("retires devices whose sessions all expired, and keeps the rest", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const devices = yield* Devices;
      const auth = yield* Auth;
      const user = yield* users.create({ displayName: null });
      const newDevice = (name: string) =>
        devices.create({ userId: user.id, app: "health-ios", platform: "ios", name });

      // Signed in at day 0 and never again: its refresh token expires after 90 days.
      const gone = yield* newDevice("Old iPhone");
      yield* auth.issueSession(user.id, gone.id);
      // Signed in at day 0 too, but refreshed at day 89, so still signed in.
      const active = yield* newDevice("iPhone");
      const tokens = yield* auth.issueSession(user.id, active.id);
      yield* TestClock.adjust(89 * day);
      yield* auth.refresh(tokens.refreshToken);

      yield* TestClock.adjust(3 * day);
      // No session at all, but only just created: it may be signing in right now.
      const signingIn = yield* newDevice("New iPhone");

      assert.strictEqual(yield* retireSignedOutDevices(), 1);
      assert.isTrue(Option.isNone(yield* devices.findById(gone.id)));
      assert.isTrue(Option.isSome(yield* devices.findById(active.id)));
      assert.isTrue(Option.isSome(yield* devices.findById(signingIn.id)));
      const sql = (yield* TestStores).sqlFor(user.id);
      assert.deepStrictEqual(sql?.exec("SELECT device FROM retired_devices"), [
        { device: gone.id },
      ]);

      // A day later, the one that never got a session goes too.
      yield* TestClock.adjust(2 * day);
      assert.strictEqual(yield* retireSignedOutDevices(), 1);
      assert.isTrue(Option.isNone(yield* devices.findById(signingIn.id)));
      assert.strictEqual(yield* retireSignedOutDevices(), 0);
    }).pipe(Effect.provide(Layer.mergeAll(TestAuth, TestUserStores))),
  );
});
