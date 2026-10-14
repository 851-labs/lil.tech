import { Effect } from "effect";

// Live sync notices (`docs/SYNC.md`): connected clients get `{ "type": "head", "seq": n }` when
// they connect and after writes that appended changes, at most once per window, always ending
// with the latest `head`. Sockets are listed from the runtime each time, never kept in memory,
// so a store that hibernates and wakes still reaches them.

/** How often, at most, a store sends notices. */
export const noticeWindowMs = 250;

/** A connected client, as the store sees it. */
export interface LiveSocket {
  readonly send: (text: string) => Effect.Effect<void>;
  readonly close: (code: number, reason: string) => Effect.Effect<void>;
  /** When the access token it connected with expires, in Unix milliseconds. */
  readonly expiresAt: number;
}

/** The store's connected clients, and a way to run something later. */
export interface LiveSockets {
  readonly list: Effect.Effect<ReadonlyArray<LiveSocket>>;
  /** Runs `task` after `delayMs`, even if the request that scheduled it has returned. */
  readonly later: (delayMs: number, task: Effect.Effect<void>) => void;
}

/** No connected clients, for stores without sockets (most tests). */
export const noLiveSockets: LiveSockets = {
  list: Effect.succeed([]),
  later: () => {},
};

/** The close code for a socket whose access token expired; the client refreshes and reconnects. */
export const tokenExpiredCloseCode = 4001;

export const headNotice = (seq: number) => JSON.stringify({ type: "head", seq });

/** Sends `head` notices to a store's sockets, coalesced to one per `noticeWindowMs`. */
export const makeLiveNotices = (sockets: LiveSockets, head: () => number) => {
  let lastSentAt = Number.NEGATIVE_INFINITY;
  let flushScheduled = false;

  const send = (now: number) =>
    Effect.gen(function* () {
      lastSentAt = now;
      const notice = headNotice(head());
      for (const socket of yield* sockets.list) {
        if (socket.expiresAt > now) yield* socket.send(notice);
      }
    });

  return {
    /** Tells connected clients about new changes, now or at the end of the current window. */
    notify: (now: number) =>
      Effect.suspend(() => {
        if (now - lastSentAt >= noticeWindowMs) return send(now);
        if (!flushScheduled) {
          flushScheduled = true;
          const at = lastSentAt + noticeWindowMs;
          // The latest `head` when the window ends, so the last write in a burst is announced.
          sockets.later(
            at - now,
            Effect.suspend(() => {
              flushScheduled = false;
              return send(at);
            }),
          );
        }
        return Effect.void;
      }),
    /** Closes sockets whose access token has expired. */
    closeExpired: (now: number) =>
      Effect.gen(function* () {
        for (const socket of yield* sockets.list) {
          if (socket.expiresAt <= now) {
            yield* socket.close(tokenExpiredCloseCode, "The access token expired");
          }
        }
      }),
    /** When the next connected socket's token expires, or `null`. */
    nextExpiry: Effect.map(sockets.list, (list) =>
      list.length === 0 ? null : Math.min(...list.map((socket) => socket.expiresAt)),
    ),
  };
};
