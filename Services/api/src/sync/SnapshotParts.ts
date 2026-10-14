import { Clock, Context, Effect, Layer, Option, Redacted, Schema } from "effect";
import { jwtVerify, SignJWT } from "jose";
import { SessionKey } from "../auth/Tokens.ts";
import type { Snapshot } from "../store/Snapshots.ts";
import type { SnapshotManifest } from "./SyncApi.ts";

// Downloading snapshot parts (`docs/SYNC.md`): manifests carry short-lived signed URLs, which
// stream the part from R2 without an `Authorization` header, so background downloads work.

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
    /** The part key a token grants, if it's genuine and unexpired. */
    readonly verify: (token: string) => Effect.Effect<string, InvalidPartUrl>;
  }
>()("lil/api/sync/PartUrls") {
  static readonly layer = Layer.effect(
    PartUrls,
    Effect.gen(function* () {
      const secret = new TextEncoder().encode(Redacted.value(yield* SessionKey));
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
        verify: Effect.fn("PartUrls.verify")(function* (token) {
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
          if (typeof payload.sub !== "string" || !payload.sub.startsWith("snapshots/")) {
            return yield* new InvalidPartUrl({ message: "Not a snapshot part" });
          }
          return payload.sub;
        }),
      });
    }),
  );
}

/** Reading snapshot parts (R2 in the Worker, built per request). */
export class SnapshotParts extends Context.Service<
  SnapshotParts,
  {
    readonly open: (
      key: string,
    ) => Effect.Effect<
      Option.Option<{ readonly body: ReadableStream<Uint8Array>; readonly size: number }>
    >;
  }
>()("lil/api/sync/SnapshotParts") {}

/** A stored snapshot as clients get it, with part URLs on `origin`. */
export const toManifest = Effect.fnUntraced(function* (snapshot: Snapshot, origin: string) {
  const urls = yield* PartUrls;
  const entities = yield* Effect.forEach(snapshot.entities, (entity) =>
    Effect.forEach(entity.parts, (part) =>
      urls.sign(part.key).pipe(
        Effect.map((token) => ({
          url: `${origin}/v1/sync/parts?token=${token}`,
          records: part.records,
          bytes: part.bytes,
          sha256: part.sha256,
        })),
      ),
    ).pipe(Effect.map((parts) => ({ entity: entity.entity, parts }))),
  );
  return {
    id: snapshot.id,
    seq: snapshot.seq,
    epoch: snapshot.epoch,
    createdAt: snapshot.createdAt,
    entities,
  } satisfies typeof SnapshotManifest.Type;
});
