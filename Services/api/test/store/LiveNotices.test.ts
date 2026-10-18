import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import type { Mutation } from "../../src/store/Changes.ts";
import { createEntityTable } from "../../src/store/Entities.ts";
import {
  answerCloseCode,
  type LiveSocket,
  type LiveSockets,
  noticeWindowMs,
} from "../../src/store/LiveNotices.ts";
import { entities } from "../../src/store/Registry.ts";
import { makeUserStore } from "../../src/store/UserStore.ts";
import { makeTestStoreSql } from "./TestStoreSql.ts";
import { makeTestSnapshotFiles, testNote, testNoteMutation } from "./TestUserStores.ts";

/** Sockets that record what they're sent, and a `later` the test runs by hand. */
const makeSockets = () => {
  const sent = new Map<string, Array<unknown>>();
  const closed = new Map<string, number>();
  const connected: Array<LiveSocket> = [];
  const pending: Array<{ at: number; task: Effect.Effect<void> }> = [];
  let now = 0;
  const connect = (name: string, expiresAt: number): LiveSocket => {
    sent.set(name, []);
    const socket: LiveSocket = {
      send: (text) => Effect.sync(() => void sent.get(name)?.push(JSON.parse(text))),
      close: (code) =>
        Effect.sync(() => {
          closed.set(name, code);
          connected.splice(connected.indexOf(socket), 1);
        }),
      expiresAt,
    };
    connected.push(socket);
    return socket;
  };
  const sockets: LiveSockets = {
    list: Effect.sync(() => [...connected]),
    later: (delayMs, task) => void pending.push({ at: now + delayMs, task }),
  };
  /** Runs the scheduled tasks that are due by `at`. */
  const runUntil = (at: number) =>
    Effect.gen(function* () {
      now = at;
      for (const due of pending.filter((task) => task.at <= at)) {
        pending.splice(pending.indexOf(due), 1);
        yield* due.task;
      }
    });
  return { sockets, sent, closed, connect, runUntil, setNow: (at: number) => (now = at) };
};

const makeStore = (sockets: LiveSockets, sql = makeTestStoreSql()) => {
  const store = makeUserStore(sql, [...entities, testNote], makeTestSnapshotFiles().files, sockets);
  if (sql.exec("SELECT name FROM sqlite_master WHERE name = 'test_note'").length === 0) {
    sql.script(createEntityTable(testNote));
  }
  return { sql, store };
};

const write = (store: ReturnType<typeof makeStore>["store"], ...ids: Array<string>) =>
  store.applyMutations(ids.map((id): Mutation => testNoteMutation(id)));

describe("live notices", () => {
  it.effect("greet a client with the head, then announce writes", () =>
    Effect.gen(function* () {
      const live = makeSockets();
      const { store } = makeStore(live.sockets);
      yield* write(store, "a");
      yield* store.liveConnected(live.connect("phone", 15 * 60 * 1000));
      assert.deepStrictEqual(live.sent.get("phone"), [{ type: "head", seq: 1 }]);

      yield* TestClock.adjust(`${noticeWindowMs} millis`);
      yield* write(store, "b");
      assert.deepStrictEqual(live.sent.get("phone")?.at(-1), { type: "head", seq: 2 });
    }),
  );

  it.effect("close every socket when the account is deleted, and turn new ones away", () =>
    Effect.gen(function* () {
      const live = makeSockets();
      const { store } = makeStore(live.sockets);
      yield* store.liveConnected(live.connect("phone", 15 * 60 * 1000));
      yield* store.liveConnected(live.connect("mac", 15 * 60 * 1000));
      yield* store.deleteAll();
      // 4001: the client refreshes, which fails for a deleted account and signs it out.
      assert.deepStrictEqual(Object.fromEntries(live.closed), { phone: 4001, mac: 4001 });

      // A token that still verifies doesn't get a connection either, nor a greeting.
      yield* store.liveConnected(live.connect("ipad", 15 * 60 * 1000));
      assert.strictEqual(live.closed.get("ipad"), 4001);
      assert.deepStrictEqual(live.sent.get("ipad"), []);
    }),
  );

  it.effect("coalesce a burst into one notice per window, ending with the latest head", () =>
    Effect.gen(function* () {
      const live = makeSockets();
      const { store } = makeStore(live.sockets);
      live.connect("phone", 15 * 60 * 1000);
      yield* write(store, "a");
      yield* TestClock.adjust("50 millis");
      live.setNow(50);
      yield* write(store, "b");
      yield* TestClock.adjust("50 millis");
      live.setNow(100);
      yield* write(store, "c");
      // Only the first write was announced so far...
      assert.deepStrictEqual(live.sent.get("phone"), [{ type: "head", seq: 1 }]);
      // ...and the window's end announces the last one.
      yield* live.runUntil(noticeWindowMs);
      assert.deepStrictEqual(live.sent.get("phone"), [
        { type: "head", seq: 1 },
        { type: "head", seq: 3 },
      ]);
    }),
  );

  it.effect("don't send a late window's notice again after a newer one went out", () =>
    Effect.gen(function* () {
      const live = makeSockets();
      const { store } = makeStore(live.sockets);
      live.connect("phone", 15 * 60 * 1000);
      yield* write(store, "a");
      yield* TestClock.adjust("100 millis");
      live.setNow(100);
      yield* write(store, "b");
      // The window's flush is late; a write after the window is announced right away.
      yield* TestClock.adjust("160 millis");
      live.setNow(260);
      yield* write(store, "c");
      yield* live.runUntil(260);
      assert.deepStrictEqual(live.sent.get("phone"), [
        { type: "head", seq: 1 },
        { type: "head", seq: 3 },
      ]);
    }),
  );

  it.effect("a broken socket fails neither the write nor the other clients' notices", () =>
    Effect.gen(function* () {
      const live = makeSockets();
      const { store } = makeStore(live.sockets);
      const broken = live.connect("broken", 15 * 60 * 1000);
      Object.assign(broken, { send: () => Effect.die("The socket is gone") });
      live.connect("phone", 15 * 60 * 1000);
      assert.deepStrictEqual(yield* write(store, "a"), { head: 1, appended: 1 });
      assert.deepStrictEqual(live.sent.get("phone"), [{ type: "head", seq: 1 }]);
    }),
  );

  it.effect("only reach the store's own clients", () =>
    Effect.gen(function* () {
      const ada = makeSockets();
      const bob = makeSockets();
      const adaStore = makeStore(ada.sockets).store;
      makeStore(bob.sockets);
      ada.connect("ada's phone", 15 * 60 * 1000);
      bob.connect("bob's phone", 15 * 60 * 1000);
      yield* write(adaStore, "a");
      assert.lengthOf(ada.sent.get("ada's phone") ?? [], 1);
      assert.lengthOf(bob.sent.get("bob's phone") ?? [], 0);
    }),
  );

  it.effect("still reach clients after the store hibernates and wakes", () =>
    Effect.gen(function* () {
      const live = makeSockets();
      const { sql } = makeStore(live.sockets);
      live.connect("phone", 15 * 60 * 1000);
      // A new instance over the same database and sockets, as after waking up.
      const { store } = makeStore(live.sockets, sql);
      yield* write(store, "a");
      assert.deepStrictEqual(live.sent.get("phone"), [{ type: "head", seq: 1 }]);
    }),
  );

  it.effect("close a client's socket with 4001 when its token expires", () =>
    Effect.gen(function* () {
      const live = makeSockets();
      const { sql, store } = makeStore(live.sockets);
      const expiresAt = 15 * 60 * 1000;
      yield* store.liveConnected(live.connect("phone", expiresAt));
      yield* store.liveConnected(live.connect("mac", expiresAt * 2));
      // The alarm is set for the first expiry.
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), expiresAt);

      yield* TestClock.adjust("15 minutes");
      yield* store.alarm();
      assert.strictEqual(live.closed.get("phone"), 4001);
      assert.isFalse(live.closed.has("mac"));
      assert.strictEqual(yield* Effect.promise(() => sql.getAlarm()), expiresAt * 2);
      // An expired client doesn't get notices meanwhile.
      yield* write(store, "a");
      assert.lengthOf(live.sent.get("mac") ?? [], 2);
    }),
  );
});

describe("answerCloseCode", () => {
  it("answers codes that can't be sent with 1000", () => {
    assert.strictEqual(answerCloseCode(1000), 1000);
    assert.strictEqual(answerCloseCode(1001), 1001);
    assert.strictEqual(answerCloseCode(4001), 4001);
    assert.strictEqual(answerCloseCode(1005), 1000);
    assert.strictEqual(answerCloseCode(1006), 1000);
    assert.strictEqual(answerCloseCode(1015), 1000);
  });
});
