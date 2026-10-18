import { Effect } from "effect";

// Live sync notices (`docs/SYNC.md`): connected clients get `{ "type": "head", "seq": n }` when
// they connect and after writes that appended changes, at most once per window, always ending
// with the latest `head`. Sockets are listed from the runtime each time, never kept in memory,
// so a store that hibernates and wakes still reaches them.

/** How often, at most, a store sends notices. */
export const noticeWindowMs = 250;

/**
 * The header the Worker sets when it hands a live connection to a store: when the client's
 * access token expires, in Unix milliseconds.
 */
export const sessionExpiresHeader = "x-lil-session-expires";

/** A connected client, as the store sees it. */
export interface LiveSocket {
  readonly send: (text: string) => Effect.Effect<void>;
  /** Closes the socket. Afterwards it's no longer listed, even while it finishes closing. */
  readonly close: (code: number, reason: string) => Effect.Effect<void>;
  /** When the access token it connected with expires, in Unix milliseconds. */
  readonly expiresAt: number;
}

/** The store's connected clients, and a way to run something later. */
export interface LiveSockets {
  /** The open sockets: not closed, and not being closed. */
  readonly list: Effect.Effect<ReadonlyArray<LiveSocket>>;
  /** Runs `task` after `delayMs`, even if the request that scheduled it has returned. */
  readonly later: (delayMs: number, task: Effect.Effect<void>) => void;
}

/** No connected clients, for stores without sockets (most tests). */
export const noLiveSockets: LiveSockets = {
  list: Effect.succeed([]),
  later: () => {},
};

/**
 * The close code for a socket whose access token is no longer good: it expired, or the account was
 * deleted. The client refreshes its session and reconnects; for a deleted account the refresh
 * fails, which signs it out. Every app version treats 4001 this way, so it's reused for deletion.
 */
export const tokenExpiredCloseCode = 4001;

export const headNotice = (seq: number) => JSON.stringify({ type: "head", seq });

/**
 * Runs something for one socket without letting it fail the rest: a broken socket mustn't fail
 * the write that triggered a notice, or keep other clients from getting it.
 */
const forSocket = (effect: Effect.Effect<void>) =>
  effect.pipe(Effect.catchCause((cause) => Effect.logWarning("Live socket failed", cause)));

/** Sends `head` notices to a store's sockets, coalesced to one per `noticeWindowMs`. */
export const makeLiveNotices = (sockets: LiveSockets, head: () => number) => {
  let lastSentAt = Number.NEGATIVE_INFINITY;
  let lastSentHead: number | undefined;
  let flushScheduled = false;

  const send = (now: number) =>
    Effect.gen(function* () {
      const seq = head();
      lastSentAt = Math.max(lastSentAt, now);
      if (seq === lastSentHead) return;
      lastSentHead = seq;
      const notice = headNotice(seq);
      for (const socket of yield* sockets.list) {
        if (socket.expiresAt > now) yield* forSocket(socket.send(notice));
      }
    }).pipe(Effect.catchCause((cause) => Effect.logWarning("Live notice failed", cause)));

  return {
    /** Tells connected clients about new changes, now or at the end of the current window. */
    notify: (now: number) =>
      Effect.suspend(() => {
        if (now - lastSentAt >= noticeWindowMs) return send(now);
        if (!flushScheduled) {
          flushScheduled = true;
          const at = lastSentAt + noticeWindowMs;
          // The latest `head` when the window ends, so the last write in a burst is announced.
          // If a notice already went out meanwhile with that head, nothing is sent again.
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
    /** Closes every socket, e.g. once the account is deleted, so clients sign out at once. */
    closeAll: (reason: string) =>
      Effect.gen(function* () {
        for (const socket of yield* sockets.list) {
          yield* forSocket(socket.close(tokenExpiredCloseCode, reason));
        }
      }),
    /** Closes sockets whose access token has expired. */
    closeExpired: (now: number) =>
      Effect.gen(function* () {
        for (const socket of yield* sockets.list) {
          if (socket.expiresAt <= now) {
            yield* forSocket(socket.close(tokenExpiredCloseCode, "The access token expired"));
          }
        }
      }),
    /** When the next open socket's token expires, or `null`. */
    nextExpiry: Effect.map(sockets.list, (list) =>
      list.length === 0 ? null : Math.min(...list.map((socket) => socket.expiresAt)),
    ),
  };
};

/**
 * The code to close a socket with in answer to a client's close. Codes like 1005 (no status) and
 * 1006 (abnormal closure) only describe a close and can't be sent, so they're answered with 1000.
 */
export const answerCloseCode = (code: number) =>
  code === 1000 ||
  (code >= 1001 && code <= 1003) ||
  (code >= 1007 && code <= 1014) ||
  (code >= 3000 && code <= 4999)
    ? code
    : 1000;
