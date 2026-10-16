import { Clock, Context, Effect, Layer, Option, Redacted, Schema } from "effect";
import { jwtVerify, SignJWT } from "jose";
import { SessionKey } from "../auth/Tokens.ts";
import type { Snapshot } from "../store/Snapshots.ts";
import type { SnapshotManifest } from "./SyncApi.ts";

// Downloading snapshot parts (`docs/SYNC.md`): manifests carry short-lived signed URLs, which
// stream the part from R2 without an `Authorization` header, so background downloads work.
// Health blobs' download URLs are signed the same way.

/** How long a part URL works. */
export const partUrlLifetimeMs = 15 * 60 * 1000;

/** Signed part URLs are JWTs for this audience, so they can't pass for access tokens. */
const partAudience = "lil/snapshot-part";

export class InvalidPartUrl extends Schema.TaggedError<InvalidPartUrl>()("InvalidPartUrl", {
  message: Schema.String,
}) {}

/** Signs and checks part URL tokens, with the stage's session key. */
export class PartUrls extends Context.Service<
  PartUrls,
  {
    /** A token for downloading `key` until `partUrlLifetimeMs` from now. */
    readonly sign: (key: string) => Effect.Effect<string>;
    /** The key a token grants, if it's genuine, unexpired and under `prefix`. */
    readonly verify: (token: string, prefix: string) => Effect.Effect<string, InvalidPartUrl>;
  }
>()("lil/api/sync/PartUrls") {
  static readonly layer = Layer.effect(
    PartUrls,
    Effect.gen(function* () {
      const raw = new TextEncoder().encode(Redacted.value(yield* SessionKey));
      const secret = yield* Effect.promise(() =>
        crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, [
          "sign",
          "verify",
        ]),
      );
      return PartUrls.of({
        sign: Effect.fn("PartUrls.sign")(function* (key) {
          const now = yield* Clock.currentTimeMillis;
          return yield* Effect.promise(() =>
            new SignJWT({})
              .setProtectedHeader({ alg: "HS256" })
              .setAudience(partAudience)
              .setSubject(key)
              .setExpirationTime(Math.floor((now + partUrlLifetimeMs) / 1000))
              .sign(secret),
          );
        }),
        verify: Effect.fn("PartUrls.verify")(function* (token, prefix) {
          const now = yield* Clock.currentTimeMillis;
          const { payload } = yield* Effect.tryPromise({
            try: () =>
              jwtVerify(token, secret, {
                audience: partAudience,
                algorithms: ["HS256"],
                currentDate: new Date(now),
              }),
            catch: (error) => new InvalidPartUrl({ message: String(error) }),
          });
          if (typeof payload.sub !== "string" || !payload.sub.startsWith(prefix)) {
            return yield* new InvalidPartUrl({ message: `Not under ${prefix}` });
          }
          return payload.sub;
        }),
      });
    }),
  );
}

/** A byte range of a part: `offset` and an optional `length`, or the last `suffix` bytes. */
export type PartRange =
  | { readonly offset: number; readonly length?: number }
  | { readonly suffix: number };

/**
 * The range in a `Range` header, if it's one we serve: a single `bytes` range. Anything else is
 * ignored, and the whole part is sent.
 */
export const parseRange = (header: string | undefined): PartRange | undefined => {
  const match = header?.match(/^bytes=(\d*)-(\d*)$/);
  if (match === undefined || match === null) return undefined;
  const [, start = "", end = ""] = match;
  if (start === "" && end === "") return undefined;
  if (start === "") return { suffix: Number(end) };
  if (end === "") return { offset: Number(start) };
  if (Number(end) < Number(start)) return undefined;
  return { offset: Number(start), length: Number(end) - Number(start) + 1 };
};

/** An opened part, or the requested range of one. */
export interface OpenedPart {
  readonly body: ReadableStream<Uint8Array>;
  /** The whole part's size. */
  readonly size: number;
  /** Which bytes `body` holds, if a range was asked for and satisfiable. */
  readonly range?: { readonly offset: number; readonly length: number };
  readonly etag: string;
}

/** Reading snapshot parts (R2 in the Worker, built per request). */
export class SnapshotParts extends Context.Service<
  SnapshotParts,
  {
    readonly open: (
      key: string,
      range: PartRange | undefined,
    ) => Effect.Effect<Option.Option<OpenedPart>>;
  }
>()("lil/api/sync/SnapshotParts") {}

/** A stored snapshot as clients get it, with part URLs on `origin`. */
export const toManifest = Effect.fnUntraced(function* (
  snapshot: Snapshot,
  origin: string,
  urls: PartUrls["Service"],
) {
  const entities = yield* Effect.forEach(
    snapshot.entities,
    (entity) =>
      Effect.forEach(
        entity.parts,
        (part) =>
          urls.sign(part.key).pipe(
            Effect.map((token) => ({
              url: `${origin}/v1/sync/parts?token=${token}`,
              records: part.records,
              bytes: part.bytes,
              sha256: part.sha256,
            })),
          ),
        { concurrency: "unbounded" },
      ).pipe(Effect.map((parts) => ({ entity: entity.entity, parts }))),
    { concurrency: "unbounded" },
  );
  return {
    id: snapshot.id,
    seq: snapshot.seq,
    epoch: snapshot.epoch,
    createdAt: snapshot.createdAt,
    entities,
  } satisfies typeof SnapshotManifest.Type;
});
