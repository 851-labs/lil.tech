import { assert, describe, it, layer } from "@effect/vitest";
import { Effect, Exit, Option, Schema } from "effect";
import { TestClock } from "effect/testing";
import { SqlClient } from "effect/sql";
import { Connections } from "../../src/core/Connections.ts";
import { Devices } from "../../src/core/Devices.ts";
import { Identities } from "../../src/core/Identities.ts";
import { ConnectionId, DeviceId, IdentityId, SessionId, UserId } from "../../src/core/Ids.ts";
import { Users } from "../../src/core/Users.ts";
import { TestCore } from "./TestCoreDatabase.ts";

describe("IDs", () => {
  it.effect("are prefixed, sortable by creation time, and validated by their schemas", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const first = yield* users.create({ displayName: null });
      yield* TestClock.adjust("1 second");
      const second = yield* users.create({ displayName: null });
      assert.match(first.id, /^usr_[0-9a-z]{26}$/);
      assert.isTrue(first.id.slice(0, 14) < second.id.slice(0, 14), "time part increases");
      assert.isTrue(Schema.is(UserId)(first.id));
      assert.isFalse(Schema.is(DeviceId)(first.id));
      assert.isFalse(Schema.is(IdentityId)("idt_short"));
      assert.isFalse(Schema.is(SessionId)(first.id.replace("usr_", "ses_").toUpperCase()));
      assert.isFalse(Schema.is(ConnectionId)("con_"));
    }).pipe(Effect.provide(TestCore)),
  );
});

describe("users' storage", () => {
  it.effect("lists the largest stores as last measured, leaving out unmeasured ones", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const [small, large, unmeasured, remeasured] = yield* Effect.all(
        Array.from({ length: 4 }, () => users.create({ displayName: null })),
      );
      if (!small || !large || !unmeasured || !remeasured) return assert.fail("users");
      yield* users.recordStorage(small.id, 1_000);
      yield* users.recordStorage(large.id, 9_000_000);
      yield* users.recordStorage(remeasured.id, 5_000_000);
      yield* TestClock.adjust("1 hour");
      yield* users.recordStorage(remeasured.id, 2_000);

      assert.deepStrictEqual(yield* users.largestByStorage(10), [
        { id: large.id, storageBytes: 9_000_000, measuredAt: 0 },
        { id: remeasured.id, storageBytes: 2_000, measuredAt: 3_600_000 },
        { id: small.id, storageBytes: 1_000, measuredAt: 0 },
      ]);
      assert.lengthOf(yield* users.largestByStorage(1), 1);
    }).pipe(Effect.provide(TestCore)),
  );
});

layer(TestCore)("core repositories", (it) => {
  it.effect("users: create, find, delete", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const user = yield* users.create({ displayName: "Ada" });
      const found = yield* users.findById(user.id);
      assert.deepStrictEqual(
        Option.map(found, (u) => u.displayName),
        Option.some("Ada"),
      );
      yield* users.delete(user.id);
      assert.isTrue(Option.isNone(yield* users.findById(user.id)));
    }),
  );

  it.effect("identities: one account per provider subject, found by provider and subject", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const identities = yield* Identities;
      const user = yield* users.create({ displayName: null });
      const apple = yield* identities.create({
        userId: user.id,
        provider: "apple",
        subject: "001234.abcd",
        email: "x@privaterelay.appleid.com",
        emailVerified: true,
      });
      const found = yield* identities.find("apple", "001234.abcd");
      assert.deepStrictEqual(
        Option.map(found, (i) => [i.id, i.emailVerified]),
        Option.some([apple.id, true]),
      );
      assert.isTrue(Option.isNone(yield* identities.find("google", "001234.abcd")));

      // The same Apple account can't belong to a second user.
      const other = yield* users.create({ displayName: null });
      const duplicate = yield* identities
        .create({
          userId: other.id,
          provider: "apple",
          subject: "001234.abcd",
          email: null,
          emailVerified: false,
        })
        .pipe(Effect.exit);
      assert.isTrue(Exit.isFailure(duplicate));

      // A user can link a second provider.
      yield* identities.create({
        userId: user.id,
        provider: "google",
        subject: "1089",
        email: "a@b.c",
        emailVerified: true,
      });
      assert.sameMembers(
        (yield* identities.listForUser(user.id)).map((i) => i.provider),
        ["apple", "google"],
      );
    }),
  );

  it.effect("devices: create, touch, push token", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const devices = yield* Devices;
      const user = yield* users.create({ displayName: null });
      const device = yield* devices.create({
        userId: user.id,
        app: "health-ios",
        platform: "ios",
        name: "iPhone",
      });
      yield* devices.setPushToken(device.id, "apns-token");
      yield* TestClock.adjust("1 minute");
      yield* devices.touch(device.id);
      const found = Option.getOrThrow(yield* devices.findById(device.id));
      assert.strictEqual(found.pushToken, "apns-token");
      assert.strictEqual(found.lastSeenAt, device.lastSeenAt + 60_000);
      assert.strictEqual((yield* devices.listForUser(user.id)).length, 1);
    }),
  );

  it.effect("connections: reconnecting the same account updates it instead of duplicating it", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const connections = yield* Connections;
      const user = yield* users.create({ displayName: null });
      const first = yield* connections.connect({
        userId: user.id,
        kind: "google",
        accountRef: "ada@gmail.com",
        displayName: "Gmail",
        scopes: ["gmail.readonly"],
        credentials: "ciphertext-1",
      });
      yield* connections.setStatus(first.id, "needs_reauth");
      const second = yield* connections.connect({
        userId: user.id,
        kind: "google",
        accountRef: "ada@gmail.com",
        displayName: "Gmail",
        scopes: ["gmail.readonly", "calendar.readonly"],
        credentials: "ciphertext-2",
      });
      assert.strictEqual(second.id, first.id);
      assert.deepStrictEqual(second.scopes, ["gmail.readonly", "calendar.readonly"]);
      assert.strictEqual(second.status, "active");
      assert.strictEqual(second.credentials, "ciphertext-2");

      // Apple Health is a separate connection of a different kind.
      yield* connections.connect({
        userId: user.id,
        kind: "apple_health",
        accountRef: "dev_iphone",
        displayName: "iPhone",
        scopes: [],
        credentials: null,
      });
      assert.sameMembers(
        (yield* connections.listForUser(user.id)).map((c) => c.kind),
        ["google", "apple_health"],
      );
    }),
  );

  it.effect("invalid input fails before anything is written", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const connections = yield* Connections;
      const devices = yield* Devices;
      const user = yield* users.create({ displayName: null });
      const badConnection = yield* connections
        .connect({
          userId: user.id,
          kind: "google",
          accountRef: "",
          displayName: null,
          scopes: [],
          credentials: null,
        })
        .pipe(Effect.flip);
      assert.strictEqual(badConnection._tag, "SchemaError");
      const badDevice = yield* devices
        .create({ userId: user.id, app: "", platform: "ios", name: null })
        .pipe(Effect.flip);
      assert.strictEqual(badDevice._tag, "SchemaError");
      assert.strictEqual((yield* connections.listForUser(user.id)).length, 0);
      assert.strictEqual((yield* devices.listForUser(user.id)).length, 0);
    }),
  );

  it.effect("a session's device must belong to the session's user", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const devices = yield* Devices;
      const sql = yield* SqlClient.SqlClient;
      const alice = yield* users.create({ displayName: null });
      const bob = yield* users.create({ displayName: null });
      const bobsDevice = yield* devices.create({
        userId: bob.id,
        app: "health-ios",
        platform: "ios",
        name: null,
      });
      const insert =
        yield* sql`INSERT INTO sessions (id, user_id, device_id, family_id, refresh_token_hash, created_at, expires_at)
        VALUES ('ses_mixed', ${alice.id}, ${bobsDevice.id}, 'fam', 'hash-mixed', 0, 1)`.pipe(
          Effect.exit,
        );
      assert.isTrue(Exit.isFailure(insert));
    }),
  );

  it.effect("deleting a user deletes everything that belongs to them", () =>
    Effect.gen(function* () {
      const users = yield* Users;
      const identities = yield* Identities;
      const devices = yield* Devices;
      const connections = yield* Connections;
      const sql = yield* SqlClient.SqlClient;
      const user = yield* users.create({ displayName: null });
      yield* identities.create({
        userId: user.id,
        provider: "apple",
        subject: "delete-me",
        email: null,
        emailVerified: false,
      });
      const device = yield* devices.create({
        userId: user.id,
        app: "health-mac",
        platform: "macos",
        name: null,
      });
      yield* sql`INSERT INTO sessions (id, user_id, device_id, family_id, refresh_token_hash, created_at, expires_at)
        VALUES ('ses_x', ${user.id}, ${device.id}, 'fam', 'hash-delete-me', 0, 1)`;
      yield* connections.connect({
        userId: user.id,
        kind: "apple_health",
        accountRef: device.id,
        displayName: null,
        scopes: [],
        credentials: null,
      });

      yield* users.delete(user.id);

      for (const table of ["identities", "devices", "sessions", "connections"]) {
        const rows = yield* sql.unsafe<{ n: number }>(
          `SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`,
          [user.id],
        );
        assert.strictEqual(rows[0]?.n, 0, table);
      }
    }),
  );
});
